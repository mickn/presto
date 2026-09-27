import AppKit
import ApplicationServices
import CoreGraphics

/// Synthetic keyboard input. Posting events needs the Accessibility permission.
enum Keyboard {
    enum Key: CGKeyCode {
        case t = 0x11, w = 0x0D, n = 0x2D, m = 0x2E, f = 0x03, q = 0x0C, three = 0x14
    }

    /// Media keys, as sent by the F7–F9 keys.
    enum MediaKey: Int {
        case playPause = 16, next = 17, previous = 18
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// A private event source, so modifier keys the user is still holding (the shortcut) don't leak in.
    private static let source = CGEventSource(stateID: .privateState)

    static func press(_ key: Key, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    static func type(_ text: String) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index ..< min(index + 16, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            index += chunk.count
        }
    }

    static func media(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (key.rawValue << 16) | (state << 8), data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Output volume and mute, through AppleScript's `set volume`, which runs in-process and needs no permission.
enum SystemAudio {
    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    static var volume: Int { Int(run("output volume of (get volume settings)")?.int32Value ?? 50) }
    static var isMuted: Bool { run("output muted of (get volume settings)")?.booleanValue ?? false }

    static func setVolume(_ level: Int) {
        let clamped = max(0, min(100, level))
        run("set volume output volume \(clamped)")
        if clamped > 0 { run("set volume without output muted") }
    }

    static func setMuted(_ muted: Bool) {
        run(muted ? "set volume with output muted" : "set volume without output muted")
    }
}

enum Appearance {
    /// Returns an error message, or nil. Asks for Automation access to System Events the first time.
    static func toggleDarkMode() -> String? {
        var error: NSDictionary?
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        return number == -1743 ? "Allow Presto to control System Events in Privacy & Security → Automation" : (error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(number)")
    }
}
