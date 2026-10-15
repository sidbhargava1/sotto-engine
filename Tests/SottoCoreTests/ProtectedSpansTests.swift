// Protected spans: matching on the raw transcript, placeholders through cleanup, the swap back.
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class ProtectedSpansTests: XCTestCase {
    static let phrases = [
        ProtectedPhrase(spoken: "my calendar link", text: "https://cal.com/me"),
        ProtectedPhrase(spoken: "standup template", text: "Yesterday:  \nToday:\nBlockers: none"),
        ProtectedPhrase(spoken: "calendar link", text: "SHORTER"),
        ProtectedPhrase(spoken: "docker tests", text: "docker compose run --rm api pytest -x"),
    ]

    private func masked(_ transcript: String, _ phrases: [ProtectedPhrase] = phrases) -> String? {
        ProtectedText(transcript, phrases: phrases)?.masked
    }

    func test_matchingTable() {
        let cases: [(name: String, input: String, expected: String?)] = [
            ("mid-sentence", "sure here's my calendar link grab any slot", "sure here's ⟦1⟧ grab any slot"),
            ("whole dictation", "standup template", "⟦1⟧"),
            ("two triggers in order", "my calendar link and the standup template", "⟦1⟧ and the ⟦2⟧"),
            ("any case", "My Calendar LINK please", "⟦1⟧ please"),
            ("STT comma inside", "send my calendar, link now", "send ⟦1⟧ now"),
            ("STT full stop and comma inside", "my. calendar, link.", "⟦1⟧."),
            ("trailing punctuation stays outside", "send my calendar link.", "send ⟦1⟧."),
            ("any whitespace", "my  calendar\tlink", "⟦1⟧"),
            ("longest wins over a shorter overlap", "the calendar link and my calendar link", "the ⟦1⟧ and ⟦2⟧"),
            ("whole words only", "my calendar linked and xdocker tests", nil),
            ("no match", "nothing to see", nil),
            ("hyphen separates", "my calendar - link", "⟦1⟧"),
            ("the same trigger twice", "docker tests then docker tests", "⟦1⟧ then ⟦2⟧"),
        ]
        for c in cases { XCTAssertEqual(masked(c.input), c.expected, c.name) }
    }

    func test_shorterPhraseAloneStillMatches() {
        XCTAssertEqual(masked("open the calendar link"), "open the ⟦1⟧")
    }

    func test_listOrderNeverChangesTheOutcome() {
        let a = ProtectedText("my calendar link", phrases: Self.phrases)
        let b = ProtectedText("my calendar link", phrases: Self.phrases.reversed())
        XCTAssertEqual(a, b)
    }

    func test_unusablePhrasesAreIgnored() {
        XCTAssertNil(masked("anything", [ProtectedPhrase(spoken: "  ", text: "x")]))
        XCTAssertEqual(masked("a b", [ProtectedPhrase(spoken: "a b", text: "1"), ProtectedPhrase(spoken: "A  B", text: "2")]), "⟦1⟧")
    }

    func test_regexMetacharactersAreLiteral() {
        XCTAssertEqual(masked("the a.b (c) thing", [ProtectedPhrase(spoken: "a.b (c)", text: "x")]), "the ⟦1⟧ thing")
        XCTAssertNil(masked("axb c", [ProtectedPhrase(spoken: "a.b c", text: "x")]))
    }

    func test_aTranscriptWithOurBracketsIsLeftAlone() {
        XCTAssertNil(masked("my calendar link ⟦1⟧"))
    }

    // MARK: restoring

    func test_restoreSwapsEachPlaceholderOnceAndKeepsTheTextExact() throws {
        let p = try XCTUnwrap(ProtectedText("here's my calendar link and the standup template", phrases: Self.phrases))
        let restored = p.restoring("Here's ⟦1⟧ and the ⟦2⟧.")
        XCTAssertEqual(restored, "Here's https://cal.com/me and the Yesterday:  \nToday:\nBlockers: none.")
    }

    func test_restoreRefusesADroppedRepeatedOrInventedPlaceholder() throws {
        let p = try XCTUnwrap(ProtectedText("my calendar link and docker tests", phrases: Self.phrases))
        let bad = [
            "Here is ⟦1⟧.",                  // dropped the second
            "⟦1⟧ ⟦1⟧ and ⟦2⟧",               // repeated
            "⟦1⟧ and ⟦2⟧ and ⟦3⟧",           // invented
            "⟦1⟧ and ⟦2",                    // cut off
            "⟦1⟧ and ⟦ 2 ⟧",                 // reformatted
            "⟦1⟧ and 2⟧ ⟦2⟧",                // stray close
            "",
        ]
        for text in bad { XCTAssertNil(p.restoring(text), text) }
        XCTAssertEqual(p.restoring("⟦2⟧ then ⟦1⟧"), "docker compose run --rm api pytest -x then https://cal.com/me", "order may change")
    }

    func test_restoreNeverRescansInsertedText() throws {
        let p = try XCTUnwrap(ProtectedText("hello there", phrases: [ProtectedPhrase(spoken: "hello there", text: "⟦1⟧ literal")]))
        XCTAssertEqual(p.restoring("⟦1⟧"), "⟦1⟧ literal")
    }

    func test_swappingInBuildsTheRawFallback() throws {
        let p = try XCTUnwrap(ProtectedText("um my calendar link thanks", phrases: Self.phrases))
        XCTAssertEqual(p.swappingIn(p.masked), "um https://cal.com/me thanks")
    }

    func test_swappingInNeverRescansInsertedText() throws {
        let phrases = [ProtectedPhrase(spoken: "first one", text: "A mentions ⟦2⟧ literally"), ProtectedPhrase(spoken: "second one", text: "B")]
        let p = try XCTUnwrap(ProtectedText("first one then second one", phrases: phrases))
        XCTAssertEqual(p.swappingIn(p.masked), "A mentions ⟦2⟧ literally then B")
        XCTAssertEqual(p.swappingIn("⟦9⟧ and ⟦1"), "⟦9⟧ and ⟦1", "unknown and unterminated runs stay")
    }

    // MARK: only the protected text

    func test_isOnlyProtected() throws {
        let cases: [(String, Bool)] = [
            ("my calendar link", true),
            ("um, my calendar link.", true),
            ("uh my calendar link uh", true),
            ("my calendar link docker tests", true),
            ("my calendar link and docker tests", false),
            ("send my calendar link", false),
            ("yeah my calendar link", false),
            ("my calendar link 5", false),
        ]
        for (input, expected) in cases {
            let p = try XCTUnwrap(ProtectedText(input, phrases: Self.phrases), input)
            XCTAssertEqual(p.isOnlyProtected, expected, input)
        }
    }

    func test_mappingTextNeverTouchesAPlaceholder() throws {
        let p = try XCTUnwrap(ProtectedText("one my calendar link two", phrases: Self.phrases))
        let mapped = p.mappingText { $0.replacingOccurrences(of: "1", with: "X").uppercased() }
        XCTAssertEqual(mapped.masked, "ONE ⟦1⟧ TWO")
        XCTAssertEqual(mapped.restoring(mapped.masked), "ONE https://cal.com/me TWO")
    }

    // MARK: the prompt

    func test_theKeepLineIsAfterTheCacheBoundaryAndOnlyWhenThereArePlaceholders() throws {
        let plain = CleanupRequest(rawTranscript: "hi", dictionary: ["Sotto"], targetContext: makeTestContext())
        let with = CleanupRequest(rawTranscript: "hi ⟦1⟧", dictionary: ["Sotto"], targetContext: makeTestContext(), protectedTokens: ["⟦1⟧"])
        XCTAssertEqual(PromptBuilder.build(plain).prefix, PromptBuilder.build(with).prefix)
        XCTAssertFalse(PromptBuilder.build(plain).tail.contains("Keep:"))
        let tail = PromptBuilder.build(with).tail
        XCTAssertTrue(tail.contains("Keep: ⟦1⟧ stand for text the speaker chose."), tail)
        XCTAssertTrue(tail.hasSuffix("<transcript>hi ⟦1⟧</transcript>"))
    }
}
