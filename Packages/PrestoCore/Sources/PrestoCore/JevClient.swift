import Foundation

/// A question for Jev's System One endpoint.
public enum JevQuestion: Sendable, Encodable {
    /// Pick one of the named categories. A `nil` description means the name says it all.
    case choice(instructions: String, criteria: [(name: String, description: String?)])
    /// Probability that the statement is true.
    case noul(instructions: String)

    private enum Keys: String, CodingKey { case type, instructions, criteria }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .choice(instructions, criteria):
            try c.encode("choice", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            var nested = c.nestedContainer(keyedBy: DynamicKey.self, forKey: .criteria)
            for item in criteria {
                try nested.encode(item.description, forKey: DynamicKey(item.name))
            }
        case let .noul(instructions):
            try c.encode("noul", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
        }
    }
}

public struct JevAnswer: Sendable, Decodable, Equatable {
    public var type: String
    public var choice: String?
    public var confidence: Double?
    public var probabilities: [String: Double]?
    public var noul: Double?

    public init(type: String, choice: String? = nil, confidence: Double? = nil, probabilities: [String: Double]? = nil, noul: Double? = nil) {
        self.type = type
        self.choice = choice
        self.confidence = confidence
        self.probabilities = probabilities
        self.noul = noul
    }
}

public struct JevResponse: Sendable, Decodable {
    public struct Usage: Sendable, Decodable { public var input_tokens: Int; public var output_tokens: Int }
    public var model: String
    public var answers: [String: JevAnswer]
    public var usage: Usage
}

public enum JevError: Error, CustomStringConvertible {
    case missingKey
    case http(Int, String)
    case transport(String)

    public var description: String {
        switch self {
        case .missingKey: "No TypeSafe API key"
        case let .http(code, body): "Jev HTTP \(code): \(body.prefix(300))"
        case let .transport(message): "Jev request failed: \(message)"
        }
    }
}

/// Anything that can answer Jev questions; the engine only sees this, so tests can fake it.
public protocol DecisionModel: Sendable {
    func ask(state: [String: String], questions: [String: JevQuestion]) async throws -> JevResponse
}

/// Talks to `POST https://api.typesafe.ai/v1/systemone`.
public final class JevClient: DecisionModel {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "jev-latest") {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    private struct Body: Encodable {
        var model: String
        var state: [String: String]
        var questions: [String: JevQuestion]
    }

    public func ask(state: [String: String], questions: [String: JevQuestion]) async throws -> JevResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(model: model, state: state, questions: questions))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JevError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw JevError.http(status, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(JevResponse.self, from: data)
    }

    /// Opens the TLS connection ahead of the first real question, so that one isn't slow.
    public func warmUp() async {
        _ = try? await ask(
            state: ["command": "hello"],
            questions: ["warm": .noul(instructions: "Is this a greeting?")]
        )
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
