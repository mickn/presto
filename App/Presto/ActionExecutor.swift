import AppKit
import PrestoCore

enum SearchEngine: String, CaseIterable, Identifiable {
    case google = "Google", duckDuckGo = "DuckDuckGo", kagi = "Kagi", bing = "Bing"
    var id: String { rawValue }

    func url(for query: String) -> URL? {
        var components: URLComponents? = switch self {
        case .google: URLComponents(string: "https://www.google.com/search")
        case .duckDuckGo: URLComponents(string: "https://duckduckgo.com/")
        case .kagi: URLComponents(string: "https://kagi.com/search")
        case .bing: URLComponents(string: "https://www.bing.com/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

/// Runs the engine's commands one at a time, in order, and remembers how to reverse each one.
@MainActor
final class ActionExecutor {
    enum Outcome: Equatable {
        case done
        case skipped(String)
        case failed(String)
    }

    var catalog: AppCatalog
    var dryRun = false
    /// Off for automated runs, so a test never pops a system dialog.
    var promptsForAccessibility = true
    var searchEngine: SearchEngine = .google
    /// Reports how each action went, for the HUD and the log.
    var onOutcome: (Action, Outcome) -> Void = { _, _ in }
    /// Reports an action that was reversed.
    var onUndo: (Action) -> Void = { _ in }

    private enum UndoStep {
        case terminate(NSRunningApplication)
        case reopen(URL)
        case keystroke(Keyboard.Key, CGEventFlags)
        case audio(volume: Int, muted: Bool)
        case darkMode
        case unhide(NSRunningApplication)
    }

    private var undoStack: [(Action, UndoStep)] = []
    private var pending: [EngineCommand] = []
    private var draining = false
    /// The app the last "open" brought forward; keystrokes wait for it to be frontmost.
    private var expectedFront: (bundleID: String, until: ContinuousClock.Instant)?

    init(catalog: AppCatalog) {
        self.catalog = catalog
    }

    func submit(_ command: EngineCommand) {
        pending.append(command)
        guard !draining else { return }
        draining = true
        Task {
            while !pending.isEmpty {
                let next = pending.removeFirst()
                await run(next)
            }
            draining = false
        }
    }

    private func run(_ command: EngineCommand) async {
        switch command {
        case let .perform(action):
            if dryRun {
                onOutcome(action, .skipped("dry run"))
                return
            }
            if action.verb == .undoLast {
                onOutcome(action, await undoLast())
                return
            }
            let outcome = await perform(action)
            onOutcome(action, outcome)
        case .undoLast:
            if !dryRun { _ = await undoLast() }
        case .cancel:
            break
        }
    }

    // MARK: Actions

    private func perform(_ action: Action) async -> Outcome {
        switch action.verb {
        case .openApp: return await openApp(action)
        case .quitApp:
            guard let app = runningApp(named: action.app) else { return .skipped("\(action.app ?? "App") isn't running") }
            return app.terminate() ? .done : .failed("\(action.app ?? "App") refused to quit")
        case .hideApp:
            guard let app = runningApp(named: action.app) else { return .skipped("\(action.app ?? "App") isn't running") }
            app.hide()
            undoStack.append((action, .unhide(app)))
            return .done
        case .newTab:
            return await keystroke(action, .t, .maskCommand, undo: .keystroke(.w, .maskCommand))
        case .closeTab:
            return await keystroke(action, .w, .maskCommand)
        case .newWindow:
            return await keystroke(action, .n, .maskCommand)
        case .closeWindow:
            let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox"]
            let isBrowser = browsers.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            return await keystroke(action, .w, isBrowser ? [.maskCommand, .maskShift] : .maskCommand)
        case .minimizeWindow:
            return await keystroke(action, .m, .maskCommand)
        case .fullscreen:
            return await keystroke(action, .f, [.maskCommand, .maskControl], undo: .keystroke(.f, [.maskCommand, .maskControl]))
        case .lockScreen:
            return await keystroke(action, .q, [.maskCommand, .maskControl])
        case .screenshot:
            return await keystroke(action, .three, [.maskCommand, .maskShift])
        case .volumeUp, .volumeDown, .setVolume, .mute, .unmute:
            let before = (volume: SystemAudio.volume, muted: SystemAudio.isMuted)
            switch action.verb {
            case .volumeUp: SystemAudio.setVolume(before.volume + 13)
            case .volumeDown: SystemAudio.setVolume(before.volume - 13)
            case .setVolume: SystemAudio.setVolume(action.level ?? before.volume)
            case .mute: SystemAudio.setMuted(true)
            default: SystemAudio.setMuted(false)
            }
            undoStack.append((action, .audio(volume: before.volume, muted: before.muted)))
            return .done
        case .playPause, .nextTrack, .previousTrack:
            guard Keyboard.isTrusted else { return needsAccessibility() }
            Keyboard.media(action.verb == .playPause ? .playPause : action.verb == .nextTrack ? .next : .previous)
            return .done
        case .openWebsite:
            guard let text = action.text, let url = URL(string: text) else { return .failed("No web address") }
            return NSWorkspace.shared.open(url) ? .done : .failed("Couldn't open \(text)")
        case .webSearch:
            guard let query = action.text, let url = searchEngine.url(for: query) else { return .failed("Nothing to search for") }
            return NSWorkspace.shared.open(url) ? .done : .failed("Couldn't open the browser")
        case .typeText:
            guard Keyboard.isTrusted else { return needsAccessibility() }
            guard let text = action.text else { return .failed("Nothing to type") }
            await waitForExpectedFront()
            Keyboard.type(text)
            return .done
        case .sleepDisplay:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            do { try process.run() } catch { return .failed(error.localizedDescription) }
            return .done
        case .darkMode:
            if let error = Appearance.toggleDarkMode() { return .failed(error) }
            undoStack.append((action, .darkMode))
            return .done
        case .undoLast:
            return await undoLast()
        case .cancel, .incomplete, .notACommand:
            return .skipped("not an action")
        }
    }

    private func openApp(_ action: Action) async -> Outcome {
        guard let name = action.app, let entry = catalog.entry(named: name) else { return .failed("Unknown app") }
        let previous = NSWorkspace.shared.frontmostApplication
        let wasRunning = runningApp(for: entry) != nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration)
            if app.isHidden { app.unhide() }
            if let id = app.bundleIdentifier ?? entry.bundleID {
                expectedFront = (id, ContinuousClock.now + .seconds(3))
            }
            if !wasRunning {
                undoStack.append((action, .terminate(app)))
            } else if let url = previous?.bundleURL, previous?.bundleIdentifier != app.bundleIdentifier {
                undoStack.append((action, .reopen(url)))
            }
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func keystroke(_ action: Action, _ key: Keyboard.Key, _ flags: CGEventFlags, undo: UndoStep? = nil) async -> Outcome {
        guard Keyboard.isTrusted else { return needsAccessibility() }
        await waitForExpectedFront()
        Keyboard.press(key, flags)
        if let undo { undoStack.append((action, undo)) }
        return .done
    }

    /// After "open Safari and new tab", the tab must land in Safari, not in whatever was in front.
    private func waitForExpectedFront() async {
        guard let expected = expectedFront else { return }
        while ContinuousClock.now < expected.until {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expected.bundleID {
                // Give the app a moment to accept key events after it comes forward.
                try? await Task.sleep(for: .milliseconds(120))
                break
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        expectedFront = nil
    }

    private func needsAccessibility() -> Outcome {
        if promptsForAccessibility { Keyboard.requestTrust() }
        return .failed("Needs Accessibility access")
    }

    // MARK: Undo

    private func undoLast() async -> Outcome {
        guard let (action, step) = undoStack.popLast() else { return .skipped("Nothing to undo") }
        switch step {
        case let .terminate(app):
            app.terminate()
        case let .reopen(url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        case let .keystroke(key, flags):
            guard Keyboard.isTrusted else { return needsAccessibility() }
            Keyboard.press(key, flags)
        case let .audio(volume, muted):
            SystemAudio.setVolume(volume)
            SystemAudio.setMuted(muted)
        case .darkMode:
            _ = Appearance.toggleDarkMode()
        case let .unhide(app):
            app.unhide()
        }
        onUndo(action)
        return .done
    }

    // MARK: Apps

    private func runningApp(for entry: AppEntry) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            ($0.bundleIdentifier != nil && $0.bundleIdentifier == entry.bundleID) || $0.bundleURL?.standardizedFileURL == entry.url.standardizedFileURL
        }
    }

    private func runningApp(named name: String?) -> NSRunningApplication? {
        guard let name, let entry = catalog.entry(named: name) else { return nil }
        return runningApp(for: entry)
    }
}
