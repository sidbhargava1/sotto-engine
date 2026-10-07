import XCTest
@testable import SottoCore

final class ThinkStripperTests: XCTestCase {
    private func run(_ pieces: [String]) -> String {
        var s = ThinkStripper()
        return pieces.map { s.feed($0) }.joined() + s.finish()
    }

    func test_LB03_thinkBlockSplitAcrossChunksIsStripped() {
        XCTAssertEqual(run(["<th", "ink>plan the", " answer</thi", "nk>\n\nHello", " there."]), "Hello there.")
    }

    func test_LB03_literalLessThanStillReachesTheTarget() {
        XCTAssertEqual(run(["Is a ", "<", " b?"]), "Is a < b?")
        XCTAssertEqual(run(["x <", "t", "hat"]), "x <that")
        XCTAssertEqual(run(["ends with <"]), "ends with <")
    }

    func test_LB03_heldPrefixIsNotEmittedEarly() {
        var s = ThinkStripper()
        XCTAssertEqual(s.feed("Hi <thi"), "Hi ")
        XCTAssertEqual(s.feed("nk>secret</think> there"), " there")
    }

    func test_LB04_unclosedThinkIsDroppedWhole() {
        XCTAssertEqual(run(["<think>never", " closed"]), "")
    }

    func test_strayCloserIsDroppedAndLeadingWhitespaceTrimmed() {
        XCTAssertEqual(run(["\n\n</think>", "\n Done."]), "Done.")
    }
}
