import Testing
@testable import PrestoCore

@Suite struct SegmenterTests {
    @Test func splitsOnJoinersAndDropsThem() {
        let s = Segmenter.split("Open Safari and then open a new tab, also mute")
        #expect(s.clauses.map(\.text) == ["open safari", "open a new tab", "mute"])
        #expect(s.clauses.map(\.isClosed) == [true, true, false])
    }

    @Test func afterThatIsAJoiner() {
        #expect(Segmenter.split("open notes after that mute").clauses.map(\.text) == ["open notes", "mute"])
    }

    @Test func marksCorrections() {
        let s = Segmenter.split("open safari no, I mean chrome")
        #expect(s.clauses.map(\.text) == ["open safari", "chrome"])
        #expect(s.clauses.map(\.isCorrection) == [false, true])
    }

    @Test func leadingNoIsNotACorrection() {
        let s = Segmenter.split("no open slack")
        #expect(s.clauses.map(\.text) == ["open slack"])
        #expect(s.clauses[0].isCorrection == false)
    }

    @Test func keepsOriginalWordsForFreeText() {
        let s = Segmenter.split("Type Hello, World and more")
        #expect(s.originalText(from: s.clauses[0].firstWord) == "Type Hello, World and more")
    }

    @Test func secondAppNameStartsANewClause() {
        let names = Segmenter.tokens(forAppNames: ["Calculator", "Chess", "Google Chrome", "App Store"])
        let s = Segmenter.split("Quit calculator chess and weather", appNames: names)
        #expect(s.clauses.map(\.text) == ["quit calculator", "chess", "weather"])
        #expect(Segmenter.split("open google chrome", appNames: names).clauses.map(\.text) == ["open google chrome"])
        #expect(Segmenter.split("open the app store", appNames: names).clauses.count == 1)
    }

    @Test func trailingJoinerClosesTheClause() {
        let s = Segmenter.split("open slack and")
        #expect(s.clauses.map(\.text) == ["open slack"])
        #expect(s.clauses[0].isClosed)
    }
}

@Suite struct FreeTextTests {
    @Test func searchQueries() {
        #expect(FreeText.searchQuery(from: "search for best pizza in Brooklyn.") == "best pizza in Brooklyn")
        #expect(FreeText.searchQuery(from: "Google how tall is the Eiffel Tower?") == "how tall is the Eiffel Tower")
        #expect(FreeText.searchQuery(from: "please look up the weather") == "the weather")
        #expect(FreeText.searchQuery(from: "what's the weather like") == "what's the weather like")
    }

    @Test func websites() {
        #expect(FreeText.websiteURL(from: "go to github dot com")?.absoluteString == "https://github.com")
        #expect(FreeText.websiteURL(from: "Open YouTube.")?.absoluteString == "https://youtube.com")
        #expect(FreeText.websiteURL(from: "take me to the apple website")?.absoluteString == "https://apple.com")
        #expect(FreeText.websiteURL(from: "visit news dot ycombinator dot com")?.absoluteString == "https://news.ycombinator.com")
        #expect(FreeText.websiteURL(from: "go to apple.com slash mac")?.absoluteString == "https://apple.com/mac")
    }

    @Test func typedText() {
        #expect(FreeText.typedText(from: "Type Hello, world.") == "Hello, world.")
        #expect(FreeText.typedText(from: "write out the words see you soon") == "see you soon")
        #expect(FreeText.typedText(from: "type") == nil)
    }
}
