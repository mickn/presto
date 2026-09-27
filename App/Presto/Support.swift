import AppKit
import Carbon.HIToolbox
import Security

// MARK: - Global shortcut

/// A system-wide shortcut through Carbon's hot key API, which needs no permission and reports
/// both press and release (so holding it can mean push-to-talk).
@MainActor
final class HotKey {
    enum Preset: String, CaseIterable, Identifiable {
        case controlOptionSpace = "⌃⌥Space"
        case optionSpace = "⌥Space"
        case controlShiftSpace = "⌃⇧Space"
        case commandShiftP = "⌘⇧P"
        var id: String { rawValue }

        var keyCode: UInt32 {
            switch self {
            case .commandShiftP: UInt32(kVK_ANSI_P)
            default: UInt32(kVK_Space)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .controlOptionSpace: UInt32(controlKey | optionKey)
            case .optionSpace: UInt32(optionKey)
            case .controlShiftSpace: UInt32(controlKey | shiftKey)
            case .commandShiftP: UInt32(cmdKey | shiftKey)
            }
        }
    }

    private static var handlers: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private let id: UInt32
    private var ref: EventHotKeyRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    /// Nil when another app already owns the shortcut.
    init?(_ preset: Preset, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.onPress = onPress
        self.onRelease = onRelease
        Self.installHandlerOnce()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5052_5354), id: id)  // 'PRST'
        let status = RegisterEventHotKey(preset.keyCode, preset.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = self
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard eventHandler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            MainActor.assumeIsolated {
                guard let hotKey = HotKey.handlers[id] else { return }
                pressed ? hotKey.onPress() : hotKey.onRelease()
            }
            return noErr
        }, types.count, &types, nil, &eventHandler)
    }
}

// MARK: - API key

/// Keeps the TypeSafe API key in the login keychain. A launch with `TYPESAFE_API_KEY` set
/// (for example through `doppler run`) stores it there, so later launches from Finder find it.
enum KeyStore {
    private static let service = "com.mickniepoth.presto"
    private static let account = "typesafe-api-key"

    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty {
            if read() != env { save(env) }
            return env
        }
        return read()
    }

    static var isStored: Bool { read() != nil }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "Presto – TypeSafe API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Event log

/// One JSON object per line in ~/Library/Logs/Presto/events.jsonl, for debugging and tests.
@MainActor
enum EventLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Presto")
    static let file = directory.appendingPathComponent("events.jsonl")
    private static let start = Date()
    private static let formatter = ISO8601DateFormatter()

    static func write(_ event: String, _ fields: [String: Any] = [:]) {
        var record = fields
        record["event"] = event
        record["time"] = formatter.string(from: Date())
        record["t"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
        print(line, terminator: "")
    }
}
