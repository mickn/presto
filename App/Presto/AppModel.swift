import AppKit
import AVFoundation
import Observation
import PrestoCore

/// One action in the HUD.
struct Chip: Identifiable, Equatable {
    enum Status: Equatable { case running, done, skipped(String), failed(String), undone }

    let id = UUID()
    var action: Action
    var status: Status = .running
    /// Seconds before the speaker finished; filled in at the end of the utterance.
    var early: Double?
}

/// Launch options for automated runs: `--simulate-audio <file>`, `--simulate-text "<sentence>"`,
/// `--dry-run`, `--exit-when-done`.
struct LaunchOptions {
    var simulateAudio: URL?
    var simulateText: String?
    /// Draws the HUD with sample content into a PNG and quits, to check its look.
    var renderHUD: URL?
    var dryRun = false
    var exitWhenDone = false

    init(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--simulate-audio": simulateAudio = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--simulate-text": simulateText = iterator.next()
            case "--render-hud": renderHUD = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--dry-run": dryRun = true
            case "--exit-when-done": exitWhenDone = true
            default: break
            }
        }
    }

    var isAutomated: Bool { simulateAudio != nil || simulateText != nil }
}

@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable { case idle, starting, listening, finishing }

    // MARK: State the UI reads

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var level: Float = 0
    private(set) var chips: [Chip] = []
    private(set) var recent: [String] = []
    private(set) var notice: String?
    private(set) var cancelled = false
    private(set) var hasKey = false
    private(set) var microphoneAllowed = false
    private(set) var accessibilityAllowed = false
    private(set) var speechReady = false

    /// The menu's setting. A `--dry-run` launch also skips execution but leaves this alone.
    var dryRun: Bool {
        didSet { executor.dryRun = dryRun || options.dryRun; UserDefaults.standard.set(dryRun, forKey: "dryRun") }
    }
    var searchEngine: SearchEngine {
        didSet { executor.searchEngine = searchEngine; UserDefaults.standard.set(searchEngine.rawValue, forKey: "searchEngine") }
    }
    var hotKeyPreset: HotKey.Preset {
        didSet { UserDefaults.standard.set(hotKeyPreset.rawValue, forKey: "hotKey"); registerHotKey() }
    }
    private(set) var hotKeyAvailable = true

    // MARK: Parts

    let options = LaunchOptions()
    private let transcriber = LiveTranscriber()
    private let executor: ActionExecutor
    private var engine: CommandEngine?
    private var client: JevClient?
    private var catalog: AppCatalog
    private var locale: Locale?
    private var hotKey: HotKey?
    private var pressedAt: ContinuousClock.Instant?
    private var holdToTalk = false
    private var hideTask: Task<Void, Never>?
    let hud = HUDController()

    init() {
        let scanned = AppCatalog.scan()
        catalog = scanned
        executor = ActionExecutor(catalog: scanned)
        dryRun = UserDefaults.standard.bool(forKey: "dryRun")
        searchEngine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
        hotKeyPreset = HotKey.Preset(rawValue: UserDefaults.standard.string(forKey: "hotKey") ?? "") ?? .controlOptionSpace
        executor.dryRun = dryRun || options.dryRun
        executor.searchEngine = searchEngine
        executor.promptsForAccessibility = !options.isAutomated

        executor.onOutcome = { [weak self] action, outcome in self?.record(action, outcome) }
        executor.onUndo = { [weak self] action in self?.markUndone(action) }
        transcriber.onTranscript = { [weak self] text in self?.heard(text) }
        transcriber.onLevel = { [weak self] level in self?.level = level }
        transcriber.onSpeechEnded = { [weak self] in self?.finishListening() }
        transcriber.onPause = { [weak self] in self?.engine?.pause() }

        hud.attach(self)
        configureEngine()
        registerHotKey()
        refreshPermissions()

        // Permissions change in System Settings while Presto runs; keep the menu honest.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshPermissions()
            }
        }

        Task {
            do {
                locale = try await LiveTranscriber.prepare()
                speechReady = true
                EventLog.write("speech_ready", ["locale": locale?.identifier ?? ""])
            } catch {
                notice = error.localizedDescription
                EventLog.write("speech_failed", ["error": error.localizedDescription])
            }
            await client?.warmUp()
            runAutomation()
        }
    }

    private func configureEngine() {
        guard let key = KeyStore.load() else {
            hasKey = false
            notice = "Add your TypeSafe API key (see README)"
            return
        }
        hasKey = true
        let client = JevClient(apiKey: key)
        self.client = client
        let engine = CommandEngine(classifier: Classifier(model: client, catalog: runningCatalog()))
        engine.onCommand = { [weak self] command in self?.command(command) }
        engine.onEvent = { [weak self] event in self?.engineEvent(event) }
        self.engine = engine
    }

    /// Installed apps plus anything running from elsewhere.
    private func runningCatalog() -> AppCatalog {
        let extra = NSWorkspace.shared.runningApplications.compactMap { app -> AppEntry? in
            guard app.activationPolicy == .regular, let url = app.bundleURL, let name = app.localizedName else { return nil }
            return AppEntry(name: name, url: url, bundleID: app.bundleIdentifier)
        }
        return catalog.adding(extra)
    }

    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = Keyboard.isTrusted
    }

    // MARK: Shortcut

    private func registerHotKey() {
        hotKey?.unregister()
        hotKey = HotKey(hotKeyPreset, onPress: { [weak self] in self?.shortcutPressed() },
                        onRelease: { [weak self] in self?.shortcutReleased() })
        hotKeyAvailable = hotKey != nil
        EventLog.write("hotkey", ["shortcut": hotKeyPreset.rawValue, "registered": hotKeyAvailable])
    }

    /// Tap: listen until you pause. Hold: listen until you let go.
    private func shortcutPressed() {
        switch phase {
        case .idle:
            pressedAt = .now
            holdToTalk = false
            startListening()
        case .listening, .starting:
            finishListening()
        case .finishing:
            break
        }
    }

    private func shortcutReleased() {
        guard let pressedAt, phase == .listening || phase == .starting else { return }
        self.pressedAt = nil
        if ContinuousClock.now - pressedAt > .milliseconds(400) {
            holdToTalk = true
            finishListening()
        }
    }

    // MARK: Listening

    func toggleListening() {
        phase == .idle ? startListening() : finishListening()
    }

    func startListening(source: LiveTranscriber.Source = .microphone) {
        guard phase == .idle else { return }
        refreshPermissions()
        guard let engine else {
            show(notice: "Presto needs a TypeSafe API key")
            return
        }
        guard let locale else {
            show(notice: speechReady ? "Speech recognition isn't available" : "Speech model is still downloading…")
            return
        }
        hideTask?.cancel()
        phase = .starting
        transcript = ""
        chips = []
        notice = nil
        cancelled = false
        level = 0
        executor.catalog = runningCatalog()
        hud.show()
        engine.begin()
        transcriber.endsOnSilence = true
        EventLog.write("listen_start", ["source": source == .microphone ? "microphone" : "file"])
        Task {
            do {
                try await transcriber.start(source: source, locale: locale)
                if phase == .starting { phase = .listening }
            } catch {
                EventLog.write("listen_failed", ["error": error.localizedDescription])
                phase = .idle
                engine.end()
                show(notice: error.localizedDescription)
                refreshPermissions()
            }
        }
    }

    func finishListening() {
        guard phase == .listening || phase == .starting else { return }
        phase = .finishing
        // Settle everything on the live transcript right away; only free text waits for the
        // accurate recognizer's final words.
        let live = transcriber.transcript
        EventLog.write("speech_end", ["transcript": live])
        engine?.end(transcript: live.isEmpty ? nil : live, speechEndedAt: transcriber.lastVoiceAt, refining: true)
        Task {
            let final = await transcriber.stop()
            EventLog.write("final_transcript", ["fast": final.fast, "accurate": final.accurate])
            let best = final.accurate.isEmpty ? final.fast : final.accurate
            if !best.isEmpty { engine?.refine(transcript: best) }
        }
    }

    private func heard(_ text: String) {
        guard phase == .listening || phase == .starting || phase == .finishing else { return }
        transcript = text
        EventLog.write("heard", ["text": text])
        if phase == .starting { phase = .listening }
        engine?.update(transcript: text)
    }

    // MARK: Engine and executor

    private func command(_ command: EngineCommand) {
        switch command {
        case let .perform(action):
            chips.append(Chip(action: action))
            executor.submit(command)
        case .undoLast:
            EventLog.write("undo_requested")
            if executor.dryRun, let index = chips.lastIndex(where: { $0.status != .undone }) {
                markUndone(chips[index].action)
            }
            executor.submit(command)
        case .cancel:
            cancelled = true
            EventLog.write("cancelled")
            Task { await transcriber.cancel() }
        }
    }

    private func engineEvent(_ event: EngineEvent) {
        switch event {
        case let .decision(clause, d):
            EventLog.write("jev", [
                "clause": clause, "verb": d.verb.rawValue, "verb_conf": d.verbConfidence,
                "app": d.app ?? "", "app_conf": d.appConfidence, "level": d.level ?? -1, "ms": Int(d.latency.milliseconds),
            ])
        case let .fired(fired):
            EventLog.write("fired", [
                "action": fired.action.description, "after_start_ms": Int(fired.afterStart.milliseconds),
                "heard": fired.transcriptAtFire,
            ])
        case .transcript:
            break
        case let .chose(picked, options):
            EventLog.write("chose", ["picked": picked, "options": options])
        case let .error(message):
            EventLog.write("jev_error", ["error": message])
        case let .finished(summary):
            for fired in summary.fired {
                if let index = chips.firstIndex(where: { $0.action == fired.action && $0.early == nil }) {
                    chips[index].early = fired.beforeSpeechEnded?.seconds
                }
            }
            recent = (chips.filter { $0.status == .done }.map(\.action.label) + recent).prefix(8).map { $0 }
            EventLog.write("finished", [
                "transcript": summary.transcript,
                "fired": summary.fired.map { ["action": $0.action.description, "early_s": ($0.beforeSpeechEnded?.seconds ?? 0), "heard": $0.transcriptAtFire] },
                "jev_calls": summary.jevCalls, "jev_mean_ms": Int(summary.meanJevLatency?.milliseconds ?? 0),
                "cancelled": summary.cancelled,
            ])
            phase = .idle
            if phase == .idle, transcriber.isRunning { Task { await transcriber.cancel() } }
            scheduleHide()
        }
    }

    private func record(_ action: Action, _ outcome: ActionExecutor.Outcome) {
        let status: Chip.Status = switch outcome {
        case .done: .done
        case let .skipped(reason): .skipped(reason)
        case let .failed(reason): .failed(reason)
        }
        if let index = chips.lastIndex(where: { $0.action == action && $0.status == .running }) {
            chips[index].status = status
        }
        if case let .failed(reason) = outcome, reason.contains("Accessibility") { refreshPermissions() }
        var fields: [String: Any] = ["action": action.description]
        switch outcome {
        case .done: fields["status"] = "done"
        case let .skipped(reason): fields["status"] = "skipped"; fields["reason"] = reason
        case let .failed(reason): fields["status"] = "failed"; fields["reason"] = reason
        }
        EventLog.write("executed", fields)
    }

    private func markUndone(_ action: Action) {
        if let index = chips.lastIndex(where: { $0.action == action }) { chips[index].status = .undone }
        EventLog.write("undone", ["action": action.description])
    }

    private func show(notice: String) {
        self.notice = notice
        hud.show()
        scheduleHide(after: .seconds(4))
    }

    private func scheduleHide(after delay: Duration = .milliseconds(2600)) {
        hideTask?.cancel()
        hideTask = Task {
            guard (try? await Task.sleep(for: delay)) != nil, phase == .idle else { return }
            hud.hide()
            if options.exitWhenDone { NSApp.terminate(nil) }
        }
    }

    // MARK: Automation

    private func runAutomation() {
        if let url = options.renderHUD {
            phase = .idle
            transcript = "Open Slack and then set the volume to 40 and search for Jev decision models"
            chips = [
                Chip(action: Action(verb: .openApp, app: "Slack"), status: .done, early: 1.8),
                Chip(action: Action(verb: .setVolume, level: 40), status: .done, early: 0.4),
                Chip(action: Action(verb: .webSearch, text: "Jev decision models"), status: .done),
                Chip(action: Action(verb: .newTab), status: .failed("Needs Accessibility access")),
            ]
            hud.show()
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                hud.snapshot(to: url)
                NSApp.terminate(nil)
            }
        } else if let url = options.simulateAudio {
            startListening(source: .file(url))
        } else if let sentence = options.simulateText {
            Task { await simulate(sentence) }
        }
    }

    /// Types a sentence into the engine at speaking pace, the way the recognizer would.
    private func simulate(_ sentence: String) async {
        guard let engine else { return }
        phase = .listening
        chips = []
        executor.catalog = runningCatalog()
        hud.show()
        engine.begin()
        EventLog.write("listen_start", ["source": "text"])
        let words = sentence.split(separator: " ").map(String.init)
        for index in words.indices {
            try? await Task.sleep(for: .milliseconds(360))
            heard(words[...index].joined(separator: " "))
        }
        try? await Task.sleep(for: .milliseconds(500))
        phase = .finishing
        engine.end(transcript: sentence)
    }
}
