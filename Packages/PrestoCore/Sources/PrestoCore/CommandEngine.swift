import Foundation

/// What the engine asks the executor to do, in order.
public enum EngineCommand: Sendable, Equatable {
    case perform(Action)
    /// Reverse the most recent action (a spoken correction, or "undo that").
    case undoLast
    /// Stop listening; nothing else from this utterance runs.
    case cancel
}

public struct FiredAction: Sendable, Equatable {
    public var action: Action
    public var clause: String
    /// Time from the first transcript of the utterance to the moment it fired.
    public var afterStart: Duration
    /// The transcript at that moment, to show how early it fired.
    public var transcriptAtFire: String
    /// Filled in when the utterance ends: how long before the end of speech it fired.
    public var beforeSpeechEnded: Duration?
}

public struct UtteranceSummary: Sendable {
    public var transcript: String
    public var fired: [FiredAction]
    public var jevCalls: Int
    public var meanJevLatency: Duration?
    public var cancelled: Bool
}

public enum EngineEvent: Sendable {
    case transcript(String)
    case decision(clause: String, ClauseDecision)
    case fired(FiredAction)
    /// The recognizers disagreed on free text and Jev picked the likelier version.
    case chose(String, from: [String])
    case error(String)
    case finished(UtteranceSummary)
}

/// Thresholds for acting on Jev's confidence.
public struct Thresholds: Sendable {
    /// Needed to act mid-sentence, while the clause may still be growing. Only reversible,
    /// harmless verbs act this early, and a wrong guess is undone when the words firm up.
    public var early: Double = 0.8
    /// The app must be this certain to act mid-sentence.
    public var earlyTarget: Double = 0.8
    /// Enough once the clause is finished and Jev's best guess is all there is.
    public var settled: Double = 0.55

    public init() {}
}

/// Turns a stream of partial transcripts into actions, firing each one as soon as Jev is sure
/// enough for how risky it is. Everything runs on the main actor; Jev calls overlap freely.
@MainActor
public final class CommandEngine {
    public var onCommand: (EngineCommand) -> Void = { _ in }
    public var onEvent: (EngineEvent) -> Void = { _ in }
    public var thresholds = Thresholds()

    private let classifier: Classifier
    private let clock = ContinuousClock()

    private enum ClauseState {
        case executed(Action, text: String, order: Int)
        case skipped(text: String)
    }

    private struct Key: Hashable { var earlier: String; var text: String }

    private var start: ContinuousClock.Instant?
    private var segmentation = Segmentation(words: [], clauses: [])
    private var decisions: [Key: ClauseDecision] = [:]
    private var inFlight: Set<Key> = []
    private var failures: [Key: Int] = [:]
    private var states: [Int: ClauseState] = [:]
    private var fired: [FiredAction] = []
    private var executedCount = 0
    private var ended = false
    private var cancelled = false
    private var finished = false
    private var speechEnd: ContinuousClock.Instant?
    /// Text of the last clause when the speaker paused; a confident clause may settle early.
    private var pausedText: String?
    /// A more accurate transcript is on its way for free-text commands.
    private var awaitingRefinement = false
    private var refinement: Segmentation?
    /// Jev's pick among differing free-text versions, per clause.
    private var arbitration: [Int: String] = [:]
    private var arbitrating: Set<Int> = []
    private var jevCalls = 0
    private var jevAnswers = 0
    private var jevLatencyTotal: Duration = .zero
    /// Bumped per utterance so late answers from the last one are dropped.
    private var generation = 0
    private var finishDeadline: Task<Void, Never>?

    public init(classifier: Classifier) {
        self.classifier = classifier
    }

    public var isActive: Bool { start != nil && !finished }

    /// Starts a fresh utterance.
    public func begin() {
        finishDeadline?.cancel()
        start = clock.now
        segmentation = Segmentation(words: [], clauses: [])
        decisions = [:]
        inFlight = []
        failures = [:]
        states = [:]
        fired = []
        executedCount = 0
        ended = false
        cancelled = false
        finished = false
        speechEnd = nil
        pausedText = nil
        awaitingRefinement = false
        refinement = nil
        arbitration = [:]
        arbitrating = []
        jevCalls = 0
        jevAnswers = 0
        jevLatencyTotal = .zero
        generation += 1
    }

    /// The whole utterance so far, finalized words plus the recognizer's current guess.
    public func update(transcript: String) {
        guard start != nil, !ended, !cancelled else { return }
        let next = Segmenter.split(transcript)
        guard next != segmentation else { return }
        segmentation = next
        onEvent(.transcript(transcript))
        requestMissing()
        evaluate()
    }

    /// The speaker stopped. Settles every clause, including free-text ones, then reports.
    /// `speechEndedAt` is when the voice actually stopped, if the caller knows; early-firing is
    /// measured against it.
    /// With `refining`, free-text commands (search, type, a web address) wait for `refine(transcript:)`
    /// so they use the most accurate words, while everything else settles right away.
    public func end(transcript: String? = nil, speechEndedAt: ContinuousClock.Instant? = nil, refining: Bool = false) {
        guard start != nil, !ended else { return }
        if let transcript, !cancelled {
            let next = Segmenter.split(transcript)
            if next != segmentation {
                segmentation = next
                onEvent(.transcript(transcript))
            }
        }
        ended = true
        awaitingRefinement = refining
        speechEnd = speechEndedAt ?? clock.now
        // Never hang the HUD on a slow or failed Jev call.
        finishDeadline = Task { [weak self] in
            // A cancelled sleep throws; only a sleep that ran out may act.
            guard (try? await Task.sleep(for: .milliseconds(1500))) != nil else { return }
            self?.stopWaitingForRefinement()
            guard (try? await Task.sleep(for: .milliseconds(2500))) != nil else { return }
            self?.finish()
        }
        requestMissing()
        evaluate()
    }

    /// A better transcript of the whole utterance, used only for the text of free-text commands.
    public func refine(transcript: String) {
        guard ended, awaitingRefinement else { return }
        refinement = Segmenter.split(transcript)
        awaitingRefinement = false
        evaluate()
    }

    /// The speaker paused. A clause Jev is already sure of doesn't need to wait for the next word.
    public func pause() {
        guard !ended, let last = segmentation.clauses.last else { return }
        pausedText = last.text
        evaluate()
    }

    // MARK: Asking Jev

    private func stopWaitingForRefinement() {
        guard awaitingRefinement else { return }
        awaitingRefinement = false
        evaluate()
    }

    private func key(for clause: Clause) -> Key {
        let earlier = segmentation.clauses.prefix(clause.index).suffix(2).map(\.text).joined(separator: " and ")
        return Key(earlier: earlier, text: clause.text)
    }

    private func needsDecision(_ clause: Clause) -> Bool {
        switch states[clause.index] {
        case let .executed(_, text, _): return text != clause.text
        case let .skipped(text): return text != clause.text
        case nil: return true
        }
    }

    private func requestMissing() {
        guard !cancelled, !finished else { return }
        for clause in segmentation.clauses where needsDecision(clause) {
            let key = key(for: clause)
            guard decisions[key] == nil, !inFlight.contains(key), failures[key, default: 0] < 2 else { continue }
            inFlight.insert(key)
            jevCalls += 1
            let classifier = classifier
            let generation = generation
            Task { [weak self] in
                do {
                    let decision = try await classifier.classify(key.text, earlier: key.earlier)
                    guard self?.generation == generation else { return }
                    self?.received(decision, for: key)
                } catch {
                    guard self?.generation == generation else { return }
                    self?.failed(key, error)
                }
            }
        }
    }

    private func received(_ decision: ClauseDecision, for key: Key) {
        inFlight.remove(key)
        guard !finished else { return }
        decisions[key] = decision
        jevAnswers += 1
        jevLatencyTotal += decision.latency
        onEvent(.decision(clause: key.text, decision))
        evaluate()
    }

    private func failed(_ key: Key, _ error: any Error) {
        inFlight.remove(key)
        failures[key, default: 0] += 1
        onEvent(.error(String(describing: error)))
        requestMissing()
        evaluate()
    }

    // MARK: Deciding

    /// Walks the clauses in order. A clause waits for the ones before it, so "open Safari and
    /// then new tab" never opens the tab first.
    private func evaluate() {
        guard !cancelled, !finished else { return }
        let clauses = segmentation.clauses
        var waiting = false

        for clause in clauses {
            let settled = clause.isClosed || ended
            let paused = !settled && clause.text == pausedText
            let nextIsCorrection = clauses.indices.contains(clause.index + 1) && clauses[clause.index + 1].isCorrection
            let decision = decisions[key(for: clause)]

            switch states[clause.index] {
            case let .executed(action, text, order):
                if text != clause.text, let decision {
                    revise(clause, executed: action, order: order, decision: decision, settled: settled)
                }
                continue
            case let .skipped(text) where text == clause.text:
                continue
            default:
                break
            }

            guard let decision else { waiting = true; break }

            let candidate = action(for: clause, decision: decision, settled: settled)
            if case .waiting = candidate { waiting = true; break }

            // "open Safari, no, Chrome": never run the clause being corrected. Free text
            // ("type no problem") keeps its words.
            if nextIsCorrection, candidate?.verb?.takesFreeText != true {
                states[clause.index] = .skipped(text: clause.text)
                continue
            }

            if case let .action(action, strong)? = candidate {
                if action.verb == .cancel {
                    if strong || settled { cancel(clause) }
                    return
                }
                let ready: Bool = switch action.verb.timing {
                case .instant: strong || settled
                case .clauseEnd: settled || (paused && strong)
                case .utteranceEnd: ended && !awaitingRefinement
                case .never: false
                }
                if ready {
                    fire(action, for: clause)
                    if action.verb.takesFreeText { break }  // it used the rest of the utterance
                    continue
                }
                if action.verb.takesFreeText { waiting = true; break }  // later clauses are its text
            }

            if settled {
                states[clause.index] = .skipped(text: clause.text)
                continue
            }
            waiting = true
            break
        }

        if ended, !waiting { finish() }
    }

    private enum Candidate {
        case action(Action, strong: Bool)
        /// Jev is choosing between versions of the free text.
        case waiting

        var verb: Verb? { if case let .action(action, _) = self { action.verb } else { nil } }
    }

    /// The action a decision supports, and whether it is strong enough to run mid-sentence.
    private func action(for clause: Clause, decision d: ClauseDecision, settled: Bool) -> Candidate? {
        var verb = d.verb
        var verbConfidence = d.verbConfidence

        // "open Safari and Slack": a bare app name continues the previous app verb.
        if !verb.isAction, let app = d.app, d.appConfidence >= thresholds.earlyTarget, clause.index > 0,
           case let .executed(previous, _, _)? = states[clause.index - 1], previous.verb.needsApp, previous.app != app {
            verb = previous.verb
            verbConfidence = d.appConfidence
        }

        guard verb.isAction, verbConfidence >= thresholds.settled else { return nil }
        var strong = verbConfidence >= thresholds.early
        var action = Action(verb: verb)

        if verb.needsApp {
            guard let app = d.app, d.appConfidence >= thresholds.settled else { return nil }
            action.app = app
            strong = strong && d.appConfidence >= thresholds.earlyTarget
        }
        if verb.needsLevel {
            guard let level = d.level, d.levelConfidence >= thresholds.settled else { return nil }
            action.level = level
            strong = strong && d.levelConfidence >= thresholds.earlyTarget
        }
        if verb.takesFreeText {
            let options = freeTextOptions(for: clause, verb: verb)
            guard let first = options.first else { return nil }
            if options.count > 1, ended, !awaitingRefinement {
                guard let chosen = arbitration[clause.index] else {
                    arbitrate(clause.index, verb: verb, options: options)
                    return .waiting
                }
                action.text = chosen
            } else {
                action.text = first
            }
        }
        return .action(action, strong: strong)
    }

    static func payload(_ verb: Verb, from text: String) -> String? {
        switch verb {
        case .webSearch: FreeText.searchQuery(from: text)
        case .typeText: FreeText.typedText(from: text)
        case .openWebsite: FreeText.websiteURL(from: text)?.absoluteString
        default: nil
        }
    }

    /// The free text as each recognizer heard it, refined first, without near-duplicates.
    private func freeTextOptions(for clause: Clause, verb: Verb) -> [String] {
        var sources: [String] = []
        if let refinement, let last = refinement.clauses.last {
            let match = refinement.clauses.indices.contains(clause.index) ? refinement.clauses[clause.index] : last
            sources.append(refinement.originalText(from: match.firstWord))
        }
        sources.append(segmentation.originalText(from: clause.firstWord))
        func comparable(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        var options: [String] = []
        for source in sources {
            guard let payload = Self.payload(verb, from: source),
                  !options.contains(where: { comparable($0) == comparable(payload) }) else { continue }
            options.append(payload)
        }
        return options
    }

    static let arbitrationInstructions = """
    A person spoke a command to their Mac, and two speech recognizers heard its text differently. \
    'request' says what kind of command it was. Which version is what the person most likely said?
    """

    /// Asks Jev which version of the free text is right. Falls back to the refined version.
    private func arbitrate(_ index: Int, verb: Verb, options: [String]) {
        guard !arbitrating.contains(index) else { return }
        arbitrating.insert(index)
        jevCalls += 1
        let model = classifier.model
        let generation = generation
        Task { [weak self] in
            let response = try? await model.ask(
                state: ["request": verb.criterion],
                questions: ["heard": .choice(instructions: Self.arbitrationInstructions,
                                             criteria: options.map { (name: $0, description: nil) })]
            )
            guard let self, self.generation == generation else { return }
            let picked = response?.answers["heard"]?.choice.flatMap { options.contains($0) ? $0 : nil } ?? options[0]
            arbitration[index] = picked
            onEvent(.chose(picked, from: options))
            evaluate()
        }
    }

    private func fire(_ action: Action, for clause: Clause) {
        // Recognizer revisions can shift clause boundaries; never run the same action twice.
        if let existing = states.values.first(where: { if case let .executed(a, _, _) = $0 { a == action } else { false } }),
           case let .executed(_, _, order) = existing {
            states[clause.index] = .executed(action, text: clause.text, order: order)
            return
        }
        if clause.isCorrection, clause.index > 0,
           case let .executed(previous, _, order)? = states[clause.index - 1],
           order == executedCount - 1, previous.verb.isReversible, previous != action {
            onCommand(.undoLast)
            fired.removeAll { $0.action == previous }
        }
        executedCount += 1
        states[clause.index] = .executed(action, text: clause.text, order: executedCount - 1)
        let record = FiredAction(
            action: action, clause: clause.text, afterStart: clock.now - (start ?? clock.now),
            transcriptAtFire: segmentation.words.joined(separator: " "), beforeSpeechEnded: nil
        )
        fired.append(record)
        onCommand(.perform(action))
        onEvent(.fired(record))
    }

    /// The recognizer rewrote a clause after it ran ("open Safari" became "open Slack").
    private func revise(_ clause: Clause, executed: Action, order: Int, decision: ClauseDecision, settled: Bool) {
        guard case let .action(action, strong)? = action(for: clause, decision: decision, settled: settled),
              strong || settled, action != executed else {
            if settled { states[clause.index] = .executed(executed, text: clause.text, order: order) }
            return
        }
        guard executed.verb.isReversible, action.verb.timing == .instant, order == executedCount - 1 else { return }
        onCommand(.undoLast)
        executedCount -= 1
        fired.removeAll { $0.action == executed }
        fire(action, for: clause)
    }

    private func cancel(_ clause: Clause) {
        cancelled = true
        states[clause.index] = .executed(Action(verb: .cancel), text: clause.text, order: executedCount)
        onCommand(.cancel)
        finish()
    }

    private func finish() {
        guard !finished, start != nil else { return }
        finished = true
        finishDeadline?.cancel()
        let end = speechEnd ?? clock.now
        let begin = start ?? end
        for i in fired.indices {
            fired[i].beforeSpeechEnded = end - (begin + fired[i].afterStart)
        }
        onEvent(.finished(UtteranceSummary(
            transcript: segmentation.words.joined(separator: " "),
            fired: fired,
            jevCalls: jevCalls,
            meanJevLatency: jevAnswers > 0 ? jevLatencyTotal / jevAnswers : nil,
            cancelled: cancelled
        )))
    }
}
