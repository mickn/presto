import Foundation

/// What Jev thinks one clause is asking for.
public struct ClauseDecision: Sendable, Equatable {
    public var verb: Verb
    public var verbConfidence: Double
    /// Catalog name, or nil when Jev picked "none".
    public var app: String?
    public var appConfidence: Double
    public var level: Int?
    public var levelConfidence: Double
    public var latency: Duration

    public init(verb: Verb, verbConfidence: Double, app: String? = nil, appConfidence: Double = 0,
                level: Int? = nil, levelConfidence: Double = 0, latency: Duration = .zero) {
        self.verb = verb
        self.verbConfidence = verbConfidence
        self.app = app
        self.appConfidence = appConfidence
        self.level = level
        self.levelConfidence = levelConfidence
        self.latency = latency
    }
}

/// Turns a clause into one Jev request with three questions answered in parallel:
/// which action, which app, and which volume level.
public struct Classifier: Sendable {
    public let model: any DecisionModel
    public let catalog: AppCatalog
    private let verbCriteria: [(name: String, description: String?)]
    private let appCriteria: [(name: String, description: String?)]
    private let levelCriteria: [(name: String, description: String?)]

    public init(model: any DecisionModel, catalog: AppCatalog) {
        self.model = model
        self.catalog = catalog
        verbCriteria = Verb.allCases.map { (name: $0.rawValue, description: $0.criterion) }
        appCriteria = catalog.entries.map { (name: $0.name, description: nil) }
            + [(name: Self.none, description: "No application is named yet, or the words so far don't identify one")]
        levelCriteria = stride(from: 0, through: 100, by: 10).map { (name: String($0), description: "\($0) percent") }
            + [(name: Self.none, description: "No volume level stated yet")]
    }

    static let none = "none"

    static let verbInstructions = """
    A person is speaking a voice command to their Mac. 'command' comes from a live transcript and may stop \
    mid-word or mid-sentence. Which action does 'command' ask the computer to take?
    """
    static let verbInstructionsWithContext = """
    A person is speaking voice commands to their Mac. 'command' comes from a live transcript and may stop \
    mid-word. 'earlier' is what they already said in the same breath and has been handled. If 'command' only \
    names a target, it continues the same kind of action as 'earlier'. Which action does 'command' ask the \
    computer to take?
    """
    static let appInstructions = """
    A person is speaking a voice command to their Mac. 'command' comes from a live transcript and may stop \
    mid-word. Which installed application does 'command' refer to? Ignore apps named only in 'earlier'.
    """
    static let levelInstructions = "If 'command' sets the volume to a specific level, which level?"

    func questions(withContext: Bool) -> [String: JevQuestion] {
        [
            "verb": .choice(instructions: withContext ? Self.verbInstructionsWithContext : Self.verbInstructions, criteria: verbCriteria),
            "app": .choice(instructions: Self.appInstructions, criteria: appCriteria),
            "level": .choice(instructions: Self.levelInstructions, criteria: levelCriteria),
        ]
    }

    public func classify(_ clause: String, earlier: String) async throws -> ClauseDecision {
        var state = ["command": clause]
        if !earlier.isEmpty { state["earlier"] = earlier }
        let start = ContinuousClock.now
        let response = try await model.ask(state: state, questions: questions(withContext: !earlier.isEmpty))
        return Self.decision(from: response.answers, catalog: catalog, latency: ContinuousClock.now - start)
    }

    static func decision(from answers: [String: JevAnswer], catalog: AppCatalog, latency: Duration) -> ClauseDecision {
        let verbAnswer = answers["verb"]
        let verb = verbAnswer?.choice.flatMap(Verb.init(rawValue:)) ?? .incomplete
        let appAnswer = answers["app"]
        let app = appAnswer?.choice.flatMap { $0 == none ? nil : catalog.entry(named: $0)?.name }
        let levelAnswer = answers["level"]
        let level = levelAnswer?.choice.flatMap { $0 == none ? nil : Int($0) }
        return ClauseDecision(
            verb: verb, verbConfidence: verbAnswer?.confidence ?? 0,
            app: app, appConfidence: app == nil ? 0 : appAnswer?.confidence ?? 0,
            level: level, levelConfidence: level == nil ? 0 : levelAnswer?.confidence ?? 0,
            latency: latency
        )
    }
}
