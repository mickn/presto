import Foundation

/// One clause of an utterance: "open safari and then new tab" has two.
public struct Clause: Sendable, Equatable {
    public var index: Int
    /// Lowercased words without punctuation, what Jev sees.
    public var text: String
    /// Index of this clause's first word in `Segmentation.words`.
    public var firstWord: Int
    /// Began with "no", "actually", "I mean" …: it replaces the clause before it.
    public var isCorrection: Bool
    /// More speech follows it, so its words are settled.
    public var isClosed: Bool
}

public struct Segmentation: Sendable, Equatable {
    /// Words as spoken, with the recognizer's casing and punctuation.
    public var words: [String]
    public var clauses: [Clause]

    /// The original words from `firstWord` to the end, for free-text commands.
    public func originalText(from firstWord: Int) -> String {
        guard firstWord < words.count else { return "" }
        return words[firstWord...].joined(separator: " ")
    }
}

/// Splits a live transcript into clauses at "and", "then", "also", commas and full stops,
/// and marks clauses that correct the one before ("open Safari, no, Chrome").
public enum Segmenter {
    static let joiners: Set<String> = ["and", "then", "also", "plus"]
    /// Longest first, so "no wait" wins over "no".
    static let corrections: [[String]] = [
        ["no", "wait"], ["no", "no"], ["scratch", "that"], ["i", "mean"], ["no"], ["actually"],
        ["sorry"], ["wait"],
    ]

    public static func normalize(_ word: String) -> String {
        let lowered = word.lowercased()
        let kept = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "." || $0 == "%" || $0 == "-"
        }
        var result = String(String.UnicodeScalarView(kept))
        while result.hasSuffix(".") || result.hasSuffix("-") || result.hasSuffix("'") { result.removeLast() }
        while result.hasPrefix("-") || result.hasPrefix("'") { result.removeFirst() }
        return result
    }

    /// App names as normalized words, for `split(_:appNames:)`.
    public static func tokens(forAppNames names: [String]) -> [[String]] {
        names.map { $0.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    /// With `appNames`, a second app name inside one clause starts a new clause, because
    /// recognizers often drop the comma in "quit Calculator, Chess".
    public static func split(_ transcript: String, appNames: [[String]] = []) -> Segmentation {
        let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        var clauses: [Clause] = []
        var current: [String] = []
        var currentStart = 0
        var currentIsCorrection = false
        var currentHasApp = false

        func close(nextStart: Int) {
            if !current.isEmpty {
                clauses.append(Clause(index: clauses.count, text: current.joined(separator: " "),
                                      firstWord: currentStart, isCorrection: currentIsCorrection, isClosed: true))
            }
            current = []
            currentStart = nextStart
            currentIsCorrection = false
            currentHasApp = false
        }

        func appNameLength(at i: Int) -> Int {
            for name in appNames where i + name.count <= words.count {
                if words[i ..< i + name.count].map(normalize) == name { return name.count }
            }
            return 0
        }

        var i = 0
        while i < words.count {
            let raw = words[i]
            let word = normalize(raw)
            let endsSentence = raw.hasSuffix(",") || raw.hasSuffix(".") || raw.hasSuffix("?") || raw.hasSuffix("!") || raw.hasSuffix(";")

            if word.isEmpty {
                if endsSentence { close(nextStart: i + 1) }
                i += 1
                continue
            }

            // "and", "then", "and then", "after that": start a new clause, drop the joiner.
            if word == "after", i + 1 < words.count, normalize(words[i + 1]) == "that" {
                close(nextStart: i + 2)
                i += 2
                continue
            }
            if joiners.contains(word) {
                close(nextStart: i + 1)
                i += 1
                continue
            }

            // "no", "actually", "I mean": a clause that replaces the one before.
            if let length = correctionLength(at: i, in: words) {
                let correctsSomething = !current.isEmpty || !clauses.isEmpty
                close(nextStart: i + length)
                // At the very start it is just a filler word.
                currentIsCorrection = correctsSomething
                i += length
                continue
            }

            let nameLength = appNameLength(at: i)
            if nameLength > 0 {
                if currentHasApp { close(nextStart: i) }
                let last = i + nameLength - 1
                current += words[i ... last].map(normalize)
                currentHasApp = true
                let raw = words[last]
                i += nameLength
                if raw.hasSuffix(",") || raw.hasSuffix(".") || raw.hasSuffix("?") || raw.hasSuffix("!") || raw.hasSuffix(";") {
                    close(nextStart: i)
                }
                continue
            }

            current.append(word)
            if endsSentence { close(nextStart: i + 1) }
            i += 1
        }
        if !current.isEmpty {
            clauses.append(Clause(index: clauses.count, text: current.joined(separator: " "),
                                  firstWord: currentStart, isCorrection: currentIsCorrection, isClosed: false))
        }
        return Segmentation(words: words, clauses: clauses)
    }

    private static func correctionLength(at i: Int, in words: [String]) -> Int? {
        for phrase in corrections where i + phrase.count <= words.count {
            let slice = words[i ..< i + phrase.count].map(normalize)
            if slice == phrase { return phrase.count }
        }
        return nil
    }
}
