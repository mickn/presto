import Foundation
import Testing
@testable import PrestoCore

/// Answers from a script keyed by the clause text; anything unscripted is "incomplete".
struct ScriptedModel: DecisionModel {
    struct Answer: Sendable {
        var verb: Verb
        var confidence: Double = 0.99
        var app: String? = nil
        var appConfidence: Double = 0.99
        var level: Int? = nil
    }

    var script: [String: Answer]
    var delay: Duration = .milliseconds(5)
    var fails = false
    /// When choosing between recognizers, pick the version containing this.
    var preferred = "~"

    func ask(state: [String: String], questions: [String: JevQuestion]) async throws -> JevResponse {
        try await Task.sleep(for: delay)
        if fails { throw JevError.transport("offline") }
        if case let .choice(_, criteria)? = questions["heard"] {
            let pick = criteria.first { $0.name.contains(preferred) }?.name ?? criteria[0].name
            let json: [String: Any] = ["model": "scripted", "usage": ["input_tokens": 1, "output_tokens": 1],
                                       "answers": ["heard": ["type": "choice", "choice": pick, "confidence": 0.9]]]
            return try JSONDecoder().decode(JevResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let a = script[state["command"] ?? ""] ?? Answer(verb: .incomplete, confidence: 0.9)
        let json: [String: Any] = [
            "model": "scripted",
            "usage": ["input_tokens": 1, "output_tokens": 1],
            "answers": [
                "verb": ["type": "choice", "choice": a.verb.rawValue, "confidence": a.confidence],
                "app": ["type": "choice", "choice": a.app ?? "none", "confidence": a.app == nil ? 0.9 : a.appConfidence],
                "level": ["type": "choice", "choice": a.level.map(String.init) ?? "none", "confidence": 0.95],
            ],
        ]
        return try JSONDecoder().decode(JevResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

let testCatalog = AppCatalog(entries: ["Safari", "Google Chrome", "Slack", "Notes", "Calculator"].map {
    AppEntry(name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app"), bundleID: nil)
})

@MainActor
final class Harness {
    let engine: CommandEngine
    var commands: [EngineCommand] = []
    var summary: UtteranceSummary?

    init(_ script: [String: ScriptedModel.Answer], fails: Bool = false, preferred: String = "~") {
        engine = CommandEngine(classifier: Classifier(model: ScriptedModel(script: script, fails: fails, preferred: preferred), catalog: testCatalog))
        engine.onCommand = { [unowned self] in commands.append($0) }
        engine.onEvent = { [unowned self] in if case let .finished(s) = $0 { summary = s } }
        engine.begin()
    }

    func say(_ partials: String...) async {
        for text in partials {
            engine.update(transcript: text)
            await settle()
        }
    }

    func end() async {
        engine.end()
        for _ in 0 ..< 200 where summary == nil { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

    var performed: [String] {
        commands.map {
            switch $0 {
            case let .perform(action): action.description
            case .undoLast: "undo"
            case .cancel: "cancel"
            }
        }
    }
}

@MainActor @Suite struct CommandEngineTests {
    @Test func opensAnAppMidSentence() async {
        let h = Harness(["open slack": .init(verb: .openApp, app: "Slack")])
        await h.say("open", "open slack")
        #expect(h.performed == ["open_app Slack"], "fires before the utterance ends")
        await h.say("open slack and")
        await h.end()
        #expect(h.performed == ["open_app Slack"], "and only once")
        #expect(h.summary?.fired.first?.beforeSpeechEnded ?? .zero > .zero)
    }

    @Test func waitsWhileTheAppIsUncertain() async {
        let h = Harness(["open sl": .init(verb: .openApp, app: "Slack", appConfidence: 0.7)])
        await h.say("open sl")
        #expect(h.performed.isEmpty)
        await h.end()
        #expect(h.performed == ["open_app Slack"], "the best guess is good enough once speech ends")
    }

    @Test func destructiveVerbsWaitForTheClauseToEnd() async {
        let h = Harness(["quit safari": .init(verb: .quitApp, app: "Safari")])
        await h.say("quit safari")
        #expect(h.performed.isEmpty)
        await h.say("quit safari and")
        #expect(h.performed == ["quit_app Safari"])
    }

    @Test func correctionUndoesTheReversibleAction() async {
        let h = Harness([
            "open safari": .init(verb: .openApp, app: "Safari"),
            "chrome": .init(verb: .openApp, app: "Google Chrome"),
        ])
        await h.say("open safari")
        await h.say("open safari no chrome")
        await h.end()
        #expect(h.performed == ["open_app Safari", "undo", "open_app Google Chrome"])
    }

    @Test func correctionHeardInTimeSkipsTheFirstAction() async {
        let h = Harness([
            "quit safari": .init(verb: .quitApp, app: "Safari"),
            "notes": .init(verb: .quitApp, app: "Notes"),
        ])
        await h.say("quit safari no notes")
        await h.end()
        #expect(h.performed == ["quit_app Notes"])
    }

    @Test func clausesRunInOrder() async {
        let h = Harness([
            "open safari": .init(verb: .openApp, app: "Safari", appConfidence: 0.7),
            "new tab": .init(verb: .newTab),
        ])
        await h.say("open safari and new tab")
        #expect(h.performed == ["open_app Safari", "new_tab"])
    }

    @Test func freeTextTakesTheRestOfTheUtterance() async {
        let h = Harness(["search for salt": .init(verb: .webSearch), "pepper": .init(verb: .notACommand)])
        await h.say("search for salt", "search for salt and pepper")
        #expect(h.performed.isEmpty, "waits for the end of the utterance")
        await h.end()
        #expect(h.performed == ["web_search \"salt and pepper\""])
    }

    @Test func freeTextKeepsCorrectionWords() async {
        let h = Harness(["type": .init(verb: .typeText), "problem": .init(verb: .notACommand)])
        await h.say("type no problem")
        await h.end()
        #expect(h.performed == ["type_text \"no problem\""])
    }

    @Test func freeTextUsesTheRefinedTranscript() async {
        let h = Harness(["search for best peak in brooklyn": .init(verb: .webSearch)])
        await h.say("search for best peak in brooklyn")
        h.engine.end(refining: true)
        await h.settle()
        #expect(h.performed.isEmpty, "waits for the accurate words")
        h.engine.refine(transcript: "Search for best pizza in Brooklyn.")
        await h.settle()
        #expect(h.performed == ["web_search \"best pizza in Brooklyn\""])
    }

    @Test func jevPicksBetweenDisagreeingRecognizers() async {
        let h = Harness(["type hello world": .init(verb: .typeText)], preferred: "hello")
        await h.say("type hello world")
        h.engine.end(refining: true)
        h.engine.refine(transcript: "Type yellow world.")
        await h.settle()
        #expect(h.performed == ["type_text \"hello world\""])
    }

    @Test func aVersionThatDoesNotParseLoses() async {
        let h = Harness(["type hello world": .init(verb: .typeText)])
        await h.say("type hello world")
        h.engine.end(refining: true)
        h.engine.refine(transcript: "Typelo World.")
        await h.settle()
        #expect(h.performed == ["type_text \"hello world\""])
    }

    @Test func refinementNeverBlocksForever() async {
        let h = Harness(["type hi": .init(verb: .typeText)])
        await h.say("type hi")
        h.engine.end(refining: true)
        try? await Task.sleep(for: .milliseconds(1800))
        #expect(h.performed == ["type_text \"hi\""])
    }

    @Test func pauseLetsAConfidentQuitRun() async {
        let h = Harness(["quit safari": .init(verb: .quitApp, app: "Safari")])
        await h.say("quit safari")
        #expect(h.performed.isEmpty)
        h.engine.pause()
        #expect(h.performed == ["quit_app Safari"])
    }

    @Test func pauseDoesNotRunAnUnsureQuit() async {
        let h = Harness(["quit safari": .init(verb: .quitApp, app: "Safari", appConfidence: 0.6)])
        await h.say("quit safari")
        h.engine.pause()
        #expect(h.performed.isEmpty)
    }

    @Test func correctedActionLeavesTheSummary() async {
        let h = Harness([
            "open safari": .init(verb: .openApp, app: "Safari"),
            "chrome": .init(verb: .openApp, app: "Google Chrome"),
        ])
        await h.say("open safari", "open safari no chrome")
        await h.end()
        #expect(h.summary?.fired.map(\.action.description) == ["open_app Google Chrome"])
    }

    @Test func setVolumeNeedsTheWholeNumber() async {
        let h = Harness([
            "set volume to 4": .init(verb: .setVolume, level: 40),
            "set volume to 40": .init(verb: .setVolume, level: 40),
        ])
        await h.say("set volume to 4", "set volume to 40")
        #expect(h.performed.isEmpty)
        await h.end()
        #expect(h.performed == ["set_volume 40%"])
    }

    @Test func cancelStopsEverything() async {
        let h = Harness(["never mind": .init(verb: .cancel)])
        await h.say("never mind")
        #expect(h.performed == ["cancel"])
        #expect(h.summary?.cancelled == true)
    }

    @Test func chatterDoesNothing() async {
        let h = Harness(["hello there": .init(verb: .notACommand)])
        await h.say("hello there")
        await h.end()
        #expect(h.performed.isEmpty)
        #expect(h.summary != nil)
    }

    @Test func bareAppNameContinuesThePreviousVerb() async {
        let h = Harness([
            "open notes": .init(verb: .openApp, app: "Notes"),
            "calculator": .init(verb: .incomplete, confidence: 0.6, app: "Calculator"),
        ])
        await h.say("open notes and calculator")
        await h.end()
        #expect(h.performed == ["open_app Notes", "open_app Calculator"])
    }

    @Test func bareAppNamesKeepThePreviousVerb() async {
        let h = Harness([
            "quit calculator": .init(verb: .quitApp, app: "Calculator"),
            "notes": .init(verb: .openApp, confidence: 0.9, app: "Notes"),
            "slack": .init(verb: .webSearch, confidence: 0.7, app: "Slack"),
        ])
        await h.say("Quit calculator, notes and slack")
        await h.end()
        #expect(h.performed == ["quit_app Calculator", "quit_app Notes", "quit_app Slack"])
    }

    @Test func recognizerRevisionSwapsAnOpenedApp() async {
        let h = Harness([
            "open safari": .init(verb: .openApp, app: "Safari"),
            "open slack": .init(verb: .openApp, app: "Slack"),
        ])
        await h.say("open safari", "open slack")
        await h.end()
        #expect(h.performed == ["open_app Safari", "undo", "open_app Slack"])
    }

    @Test func finishesEvenIfJevIsUnreachable() async {
        let h = Harness([:], fails: true)
        await h.say("open something")
        h.engine.end()
        for _ in 0 ..< 120 where h.summary == nil { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(h.summary != nil)
    }
}
