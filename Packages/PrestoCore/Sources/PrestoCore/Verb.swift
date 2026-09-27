import Foundation

/// Everything Presto can be asked to do, plus the two "not yet an action" outcomes.
/// Raw values are the category names Jev sees, so keep them stable and self-describing.
public enum Verb: String, CaseIterable, Sendable, Codable {
    case openApp = "open_app"
    case quitApp = "quit_app"
    case hideApp = "hide_app"
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case newWindow = "new_window"
    case closeWindow = "close_window"
    case minimizeWindow = "minimize_window"
    case fullscreen
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case setVolume = "set_volume"
    case mute
    case unmute
    case playPause = "play_pause"
    case nextTrack = "next_track"
    case previousTrack = "previous_track"
    case openWebsite = "open_website"
    case webSearch = "web_search"
    case typeText = "type_text"
    case lockScreen = "lock_screen"
    case sleepDisplay = "sleep_display"
    case screenshot
    case darkMode = "dark_mode"
    case undoLast = "undo_last"
    case cancel
    case incomplete
    case notACommand = "not_a_command"

    /// When a verb is allowed to run.
    public enum Timing: Sendable {
        /// Harmless and easy to reverse: runs mid-sentence, as soon as Jev is confident.
        case instant
        /// Destructive or needs every word of its clause (a number): runs once the clause is over.
        case clauseEnd
        /// Takes free text that runs to the end of the utterance.
        case utteranceEnd
        /// Not an action.
        case never
    }

    public var timing: Timing {
        switch self {
        case .openApp, .hideApp, .newTab, .newWindow, .minimizeWindow, .fullscreen,
             .volumeUp, .volumeDown, .mute, .unmute, .playPause, .nextTrack, .previousTrack,
             .darkMode, .cancel:
            return .instant
        case .quitApp, .closeTab, .closeWindow, .setVolume, .lockScreen, .sleepDisplay,
             .screenshot, .undoLast:
            return .clauseEnd
        case .openWebsite, .webSearch, .typeText:
            return .utteranceEnd
        case .incomplete, .notACommand:
            return .never
        }
    }

    public var needsApp: Bool { self == .openApp || self == .quitApp || self == .hideApp }
    public var needsLevel: Bool { self == .setVolume }
    public var takesFreeText: Bool { timing == .utteranceEnd }
    public var isAction: Bool { timing != .never }

    /// Whether a later "no, I mean …" may silently reverse it.
    public var isReversible: Bool {
        switch self {
        case .openApp, .hideApp, .newTab, .volumeUp, .volumeDown, .setVolume, .mute, .unmute,
             .darkMode, .fullscreen:
            return true
        default:
            return false
        }
    }

    /// The description Jev reads for this category.
    public var criterion: String {
        switch self {
        case .openApp: "Open, launch, start, show, bring up, or switch to an application"
        case .quitApp: "Quit, kill, or close an entire application"
        case .hideApp: "Hide an application"
        case .newTab: "Open a new tab"
        case .closeTab: "Close the current tab"
        case .newWindow: "Open a new window"
        case .closeWindow: "Close the current window"
        case .minimizeWindow: "Minimize the current window"
        case .fullscreen: "Make the current window full screen, or leave full screen"
        case .volumeUp: "Turn the volume up / make it louder"
        case .volumeDown: "Turn the volume down / make it quieter"
        case .setVolume: "Set the volume to a specific level"
        case .mute: "Mute the sound"
        case .unmute: "Unmute the sound"
        case .playPause: "Play, pause, or resume music or media"
        case .nextTrack: "Skip to the next song or track"
        case .previousTrack: "Go back to the previous song or track"
        case .openWebsite: "Go to, open, or visit a specific website or web address"
        case .webSearch: "Search the web, Google something, or look something up"
        case .typeText: "Type, write, or dictate some text"
        case .lockScreen: "Lock the screen or computer"
        case .sleepDisplay: "Turn off or sleep the display"
        case .screenshot: "Take a screenshot"
        case .darkMode: "Toggle or switch between dark mode and light mode"
        case .undoLast: "Undo or revert the previous voice command"
        case .cancel: "Cancel, never mind, stop listening"
        case .incomplete: "The command has started but it is not yet clear which action it is"
        case .notACommand: "Not a request for the computer to do something"
        }
    }

    /// Past-tense label for the HUD ("Opened", "Muted").
    public var pastTense: String {
        switch self {
        case .openApp: "Opened"
        case .quitApp: "Quit"
        case .hideApp: "Hid"
        case .newTab: "New tab"
        case .closeTab: "Closed tab"
        case .newWindow: "New window"
        case .closeWindow: "Closed window"
        case .minimizeWindow: "Minimized"
        case .fullscreen: "Full screen"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .setVolume: "Volume"
        case .mute: "Muted"
        case .unmute: "Unmuted"
        case .playPause: "Play/Pause"
        case .nextTrack: "Next track"
        case .previousTrack: "Previous track"
        case .openWebsite: "Opened"
        case .webSearch: "Searched"
        case .typeText: "Typed"
        case .lockScreen: "Locked"
        case .sleepDisplay: "Display off"
        case .screenshot: "Screenshot"
        case .darkMode: "Toggled dark mode"
        case .undoLast: "Undid last"
        case .cancel: "Cancelled"
        case .incomplete, .notACommand: ""
        }
    }
}

/// A fully specified thing to do.
public struct Action: Sendable, Hashable, Codable, CustomStringConvertible {
    public var verb: Verb
    /// Catalog name of the app, for app verbs.
    public var app: String?
    /// 0–100, for `setVolume`.
    public var level: Int?
    /// Search query, URL, or text to type, for free-text verbs.
    public var text: String?

    public init(verb: Verb, app: String? = nil, level: Int? = nil, text: String? = nil) {
        self.verb = verb
        self.app = app
        self.level = level
        self.text = text
    }

    public var description: String {
        var parts = [verb.rawValue]
        if let app { parts.append(app) }
        if let level { parts.append("\(level)%") }
        if let text { parts.append("\"\(text)\"") }
        return parts.joined(separator: " ")
    }

    /// Short label for the HUD.
    public var label: String {
        switch verb {
        case .openApp, .quitApp, .hideApp: "\(verb.pastTense) \(app ?? "")"
        case .setVolume: "Volume \(level ?? 0)%"
        case .openWebsite: "Opened \(text ?? "")"
        case .webSearch: "Searched \u{201C}\(text ?? "")\u{201D}"
        case .typeText: "Typed \u{201C}\(text ?? "")\u{201D}"
        default: verb.pastTense
        }
    }
}
