import Foundation
import PrestoCore

// Replays spoken commands against the real Jev API at speaking pace (word by word, with half-words
// the way a live recognizer reports them) and checks what the engine would have done.
//
//   TYPESAFE_API_KEY=… swift run presto-eval              # the built-in suite
//   TYPESAFE_API_KEY=… swift run presto-eval "open notes and then mute"

struct Scenario {
    var said: String
    /// Net actions after undos, in order.
    var expect: [String]
    /// These must fire before the speaker finishes.
    var early: [String] = []
}

let suite: [Scenario] = [
    Scenario(said: "open calculator and then open textedit", expect: ["open_app Calculator", "open_app TextEdit"], early: ["open_app Calculator"]),
    Scenario(said: "open notes and messages", expect: ["open_app Notes", "open_app Messages"], early: ["open_app Notes"]),
    Scenario(said: "open safari no chrome", expect: ["open_app Google Chrome"]),
    Scenario(said: "set the volume to 30 and pause the music", expect: ["set_volume 30%", "play_pause"], early: ["set_volume 30%"]),
    Scenario(said: "make it louder then skip this song", expect: ["volume_up", "next_track"], early: ["volume_up"]),
    Scenario(said: "quit calculator", expect: ["quit_app Calculator"]),
    Scenario(said: "search for best pizza in brooklyn", expect: ["web_search \"best pizza in brooklyn\""]),
    Scenario(said: "go to github dot com", expect: ["open_website \"https://github.com\""]),
    Scenario(said: "type hello world", expect: ["type_text \"hello world\""]),
    Scenario(said: "take a screenshot and switch to dark mode", expect: ["screenshot", "dark_mode"]),
    Scenario(said: "lock the screen", expect: ["lock_screen"]),
    Scenario(said: "never mind", expect: ["cancel"]),
    Scenario(said: "hey how's it going", expect: []),
    Scenario(said: "bring up my calendar and make it full screen", expect: ["open_app Calendar", "fullscreen"], early: ["open_app Calendar"]),
]

let wordsPerSecond = 2.8

guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else {
    FileHandle.standardError.write(Data("Set TYPESAFE_API_KEY\n".utf8))
    exit(2)
}

let client = JevClient(apiKey: key)
let catalog = AppCatalog.scan()
let engine = CommandEngine(classifier: Classifier(model: client, catalog: catalog))
await client.warmUp()

/// Partial transcripts a live recognizer would report, with their offsets in seconds.
func partials(for sentence: String) -> [(String, Double)] {
    let words = sentence.split(separator: " ").map(String.init)
    var result: [(String, Double)] = []
    let perWord = 1 / wordsPerSecond
    for (i, word) in words.enumerated() {
        let before = words[..<i].joined(separator: " ")
        let join = before.isEmpty ? "" : before + " "
        if word.count >= 5 {
            result.append((join + word.prefix(word.count / 2 + 1), Double(i) * perWord + perWord * 0.5))
        }
        result.append((join + word, Double(i + 1) * perWord))
    }
    return result
}

@MainActor
func run(_ scenario: Scenario) async -> Bool {
    var commands: [EngineCommand] = []
    var log: [String] = []
    var summary: UtteranceSummary?
    let t0 = ContinuousClock.now
    func stamp() -> String { String(format: "%5.2fs", (ContinuousClock.now - t0).seconds) }

    engine.onCommand = { command in
        commands.append(command)
        switch command {
        case let .perform(action): log.append("\(stamp())  ⚡ \(action)")
        case .undoLast: log.append("\(stamp())  ↩︎ undo last")
        case .cancel: log.append("\(stamp())  ✕ cancel")
        }
    }
    engine.onEvent = { event in
        switch event {
        case let .transcript(text): log.append("\(stamp())  \u{201C}\(text)\u{201D}")
        case let .error(message): log.append("\(stamp())  ! \(message)")
        case let .finished(s): summary = s
        default: break
        }
    }

    engine.begin()
    let steps = partials(for: scenario.said)
    for (text, at) in steps {
        let wait = t0 + .milliseconds(Int(at * 1000)) - ContinuousClock.now
        if wait > .zero { try? await Task.sleep(for: wait) }
        engine.update(transcript: text)
    }
    // A real recognizer confirms the end of speech a beat later.
    try? await Task.sleep(for: .milliseconds(150))
    engine.end(transcript: scenario.said)
    while summary == nil { try? await Task.sleep(for: .milliseconds(20)) }

    var net: [Action] = []
    var earlyFired: Set<String> = []
    for command in commands {
        switch command {
        case let .perform(action):
            if action.verb == .undoLast { if !net.isEmpty { net.removeLast() } } else { net.append(action) }
        case .undoLast: if !net.isEmpty { net.removeLast() }
        case .cancel: net.append(Action(verb: .cancel))
        }
    }
    for fired in summary?.fired ?? [] where (fired.beforeSpeechEnded ?? .zero) > .milliseconds(150) {
        earlyFired.insert(fired.action.description)
    }

    let got = net.map(\.description)
    let missingEarly = scenario.early.filter { !earlyFired.contains($0) }
    let pass = got == scenario.expect && missingEarly.isEmpty
    print("\(pass ? "PASS" : "FAIL")  \u{201C}\(scenario.said)\u{201D}")
    for line in log { print("        \(line)") }
    if let summary {
        for fired in summary.fired {
            let lead = (fired.beforeSpeechEnded ?? .zero).seconds + 0.15
            print("        \(fired.action) fired \(String(format: "%.2f", lead))s before speech ended, having heard \u{201C}\(fired.transcriptAtFire)\u{201D}")
        }
        let mean = summary.meanJevLatency?.milliseconds ?? 0
        print(String(format: "        %d Jev calls, mean %.0f ms", summary.jevCalls, mean))
    }
    if !pass { print("        expected \(scenario.expect), got \(got)\(missingEarly.isEmpty ? "" : ", not early: \(missingEarly)")") }
    return pass
}

let arguments = Array(CommandLine.arguments.dropFirst())
let scenarios = arguments.isEmpty ? suite : arguments.map { Scenario(said: $0, expect: []) }
var passed = 0
for scenario in scenarios where await run(scenario) { passed += 1 }
print("\n\(passed)/\(scenarios.count) passed")
exit(arguments.isEmpty && passed != scenarios.count ? 1 : 0)
