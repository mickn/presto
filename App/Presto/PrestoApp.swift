import AppKit
import ServiceManagement
import SwiftUI

@main
struct PrestoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.phase == .idle ? "bolt.horizontal.circle" : "bolt.horizontal.circle.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Text(status)
        Button(model.phase == .idle ? "Start Listening" : "Stop Listening") { model.toggleListening() }
        Text("Tap \(model.hotKeyPreset.rawValue) and speak, or hold it while you talk")

        if !model.recent.isEmpty {
            Divider()
            Section("Recent") {
                ForEach(Array(model.recent.enumerated()), id: \.offset) { _, label in Text(label) }
            }
        }

        Divider()
        Section("Setup") {
            Button(model.microphoneAllowed ? "Microphone: allowed ✓" : "Allow Microphone…") {
                Task {
                    _ = await LiveTranscriber.microphoneAccess()
                    model.refreshPermissions()
                    if !model.microphoneAllowed { openPrivacy("Privacy_Microphone") }
                }
            }
            Button(model.accessibilityAllowed ? "Accessibility: allowed ✓" : "Allow Accessibility… (for keys, media, typing)") {
                Keyboard.requestTrust()
                openPrivacy("Privacy_Accessibility")
            }
            Text(model.hasKey ? "Jev API key: found ✓" : "Jev API key: missing")
            Text(model.speechReady ? "Speech model: ready ✓" : "Speech model: preparing…")
        }

        Divider()
        Toggle("Dry Run (show, don't do)", isOn: $model.dryRun)
        Picker("Search With", selection: $model.searchEngine) {
            ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Shortcut", selection: $model.hotKeyPreset) {
            ForEach(HotKey.Preset.allCases) { Text($0.rawValue).tag($0) }
        }
        if !model.hotKeyAvailable {
            Text("That shortcut is taken by another app")
        }
        Toggle("Open at Login", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    EventLog.write("login_item_failed", ["error": error.localizedDescription])
                }
            }
        ))
        Button("Open Event Log") { NSWorkspace.shared.open(EventLog.file) }
        Divider()
        Button("Quit Presto") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var status: String {
        switch model.phase {
        case .idle: model.notice ?? "Presto is ready"
        case .starting, .listening: "Listening…"
        case .finishing: "Finishing…"
        }
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
