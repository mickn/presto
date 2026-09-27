import Foundation

/// Jev only returns numbers, so the text of a search, a URL, or words to type is cut out of the
/// transcript here once Jev has said which kind of command it is.
public enum FreeText {
    private static let politeness = #"^(?:(?:ok(?:ay)?|hey|please|can you|could you|would you|i want to|i'd like to|let's)[,\s]+)*"#

    public static func searchQuery(from text: String) -> String? {
        let verb = #"(?:search(?:\s+(?:the\s+web|the\s+internet|online|google|for))*|google(?:\s+for)?|look\s+up|find(?:\s+out)?|what(?:'s|\s+is)\s+the\s+answer\s+to)[,:\s]+"#
        return strip(text, prefix: politeness + verb, fallbackToWhole: true).flatMap(trimmed)
    }

    public static func typedText(from text: String) -> String? {
        let verb = #"(?:type|write|dictate|enter)(?:\s+out)?(?:\s+the\s+(?:words?|text|phrase))?[,:\s]+"#
        return strip(text, prefix: politeness + verb, fallbackToWhole: false).flatMap { value in
            let result = value.trimmingCharacters(in: .whitespaces)
            return result.isEmpty ? nil : result
        }
    }

    public static func websiteURL(from text: String) -> URL? {
        let verb = #"(?:go\s+to|open(?:\s+up)?|visit|navigate\s+to|pull\s+up|take\s+me\s+to|load|bring\s+up|show\s+me)(?:\s+the)?(?:\s+(?:website|site|page|web\s+page))?[,:\s]+"#
        guard var host = strip(text, prefix: politeness + verb, fallbackToWhole: true)?.lowercased() else { return nil }
        host = host.replacingOccurrences(of: #"\b(?:website|site|web\s+page|page)\b"#, with: "", options: .regularExpression)
        host = host.replacingOccurrences(of: #"\s*\bdot\b\s*"#, with: ".", options: .regularExpression)
        host = host.replacingOccurrences(of: #"\s*\bslash\b\s*"#, with: "/", options: .regularExpression)
        host = host.replacingOccurrences(of: #"^(?:https?\s*:?\s*/*\s*)"#, with: "", options: .regularExpression)
        host = host.replacingOccurrences(of: #"^the\s+"#, with: "", options: .regularExpression)
        host = host.filter { !$0.isWhitespace }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:'\""))
        guard !host.isEmpty else { return nil }
        let hostPart = host.split(separator: "/", maxSplits: 1).first.map(String.init) ?? host
        if !hostPart.contains(".") {
            host = hostPart + ".com" + host.dropFirst(hostPart.count)
        }
        guard let url = URL(string: "https://" + host), url.host != nil else { return nil }
        return url
    }

    private static func strip(_ text: String, prefix: String, fallbackToWhole: Bool) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = clean.range(of: prefix, options: [.regularExpression, .caseInsensitive]), !range.isEmpty,
           clean[range].trimmingCharacters(in: .whitespaces).isEmpty == false {
            let rest = String(clean[range.upperBound...])
            return rest.isEmpty ? nil : rest
        }
        return fallbackToWhole ? clean : nil
    }

    private static func trimmed(_ text: String) -> String? {
        let result = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".?!,;:")))
        return result.isEmpty ? nil : result
    }
}
