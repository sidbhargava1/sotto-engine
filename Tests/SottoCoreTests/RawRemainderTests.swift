import XCTest
@testable import SottoCore

final class RawRemainderTests: XCTestCase {
    func test_LB09_resumesAfterLastTypedWordNotByCharacterCount() {
        let raw = "um so send it tuesday no wait wednesday to the team"
        XCTAssertEqual(RawRemainder.after(produced: "Send it Wednesday ", raw: raw), "to the team")
    }

    func test_LB09_noAlignmentAppendsWholeRawAfterASpace() {
        XCTAssertEqual(RawRemainder.after(produced: "Totally different.", raw: "one two three"), " one two three")
    }

    func test_LB09_nothingProducedYieldsWholeRaw() {
        XCTAssertEqual(RawRemainder.after(produced: "", raw: "one two"), "one two")
    }

    func test_LB09_partialLastWordResumesAtTheNextWholeWord() {
        XCTAssertEqual(RawRemainder.after(produced: "Send it Wedn", raw: "send it wednesday to the team"), " to the team")
    }

    func test_LB09_repeatedWordPrefersTheBestContextThenTheEarliest() {
        let raw = "the cat sat on the mat by the door"
        XCTAssertEqual(RawRemainder.after(produced: "The mat, by the ", raw: raw), "door")
        XCTAssertEqual(RawRemainder.after(produced: "Hi, the ", raw: raw), "cat sat on the mat by the door")
    }

    func test_LB09_passThroughBackendResumesExactly() {
        XCTAssertEqual(RawRemainder.after(produced: "hello ", raw: "hello world"), "world")
        XCTAssertEqual(RawRemainder.after(produced: "hello world", raw: "hello world"), "")
    }

    func test_LB09_punctuationAndCaseAreIgnoredForAlignment() {
        XCTAssertEqual(RawRemainder.after(produced: "Well, it's done. ", raw: "well its done and dusted"), "and dusted")
    }
}
