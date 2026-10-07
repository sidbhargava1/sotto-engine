import XCTest
@testable import SottoCore

final class CommandParserTests: XCTestCase {
    func test_exactMatch() {
        XCTAssertEqual(CommandParser.parse("scratch that"), .scratchThat)
    }

    func test_caseAndPunctuationInsensitive() {
        XCTAssertEqual(CommandParser.parse("Scratch That."), .scratchThat)
        XCTAssertEqual(CommandParser.parse("  scratch  that  "), .scratchThat)
        XCTAssertEqual(CommandParser.parse("Scrap, stat!"), .scratchThat)
    }

    func test_everyVerbatimVariantMatches() {
        for variant in ["scratch that", "scratch that out", "scratch it", "scrap that",
                        "scrap stat", "scratch dat", "scratched that", "scratch at"] {
            XCTAssertEqual(CommandParser.parse(variant), .scratchThat, variant)
        }
    }

    func test_fuzzyMatchesCloseMishearings() {
        for heard in ["scratch hat", "scrach that", "scratches that", "scratc that", "scratch tat"] {
            XCTAssertLessThanOrEqual(CommandParser.damerauLevenshtein(heard, "scratch that"), 3, heard)
            XCTAssertEqual(CommandParser.parse(heard), .scratchThat, heard)
        }
    }

    func test_nearMissesDoNotMatch() {
        // DS-18 and friends: wrong word count, or distance <= 3 but no "scr" onset / closing /t/.
        for nearMiss in ["scratch that thought", "please scratch that", "scratch the", "watch that",
                         "catch that", "scratch this", "script that", "scratch", "that",
                         "scratch that out please now"] {
            XCTAssertNil(CommandParser.parse(nearMiss), nearMiss)
        }
    }

    func test_nearMissDistancesAreWhatTheAnchorsGuardAgainst() {
        XCTAssertEqual(CommandParser.damerauLevenshtein("scratch the", "scratch that"), 2)
        XCTAssertEqual(CommandParser.damerauLevenshtein("catch that", "scratch that"), 2)
        XCTAssertEqual(CommandParser.damerauLevenshtein("watch that", "scratch that"), 3)
        XCTAssertGreaterThanOrEqual(CommandParser.damerauLevenshtein("scratch that thought", "scratch that"), 4)
        XCTAssertGreaterThanOrEqual(CommandParser.damerauLevenshtein("script that", "scratch that"), 4)
    }

    func test_explicitRejectsDoNotMatchDespiteDistance() {
        for phrase in ["scratch test", "Scrape that."] {
            XCTAssertLessThanOrEqual(CommandParser.damerauLevenshtein(CommandParser.normalize(phrase), "scratch that"), 3, phrase)
            XCTAssertNil(CommandParser.parse(phrase), phrase)
        }
    }

    func test_damerauLevenshteinCountsTranspositionAsOne() {
        XCTAssertEqual(CommandParser.damerauLevenshtein("ab", "ba"), 1)
        XCTAssertEqual(CommandParser.damerauLevenshtein("", "abc"), 3)
        XCTAssertEqual(CommandParser.damerauLevenshtein("kitten", "sitting"), 3)
    }

    func test_ordinaryDictationDoesNotMatch() {
        XCTAssertNil(CommandParser.parse("let's grab lunch at noon"))
        XCTAssertNil(CommandParser.parse("scrap the plan"))
    }
}
