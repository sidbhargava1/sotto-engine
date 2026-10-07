import XCTest
@testable import SottoCore

final class DictionaryCodecTests: XCTestCase {
    func test_roundTrip() {
        let terms = [DictionaryTerm("FluidAudio"), DictionaryTerm("Parakeet")]
        let encoded = DictionaryCodec.encode(terms)
        XCTAssertEqual(DictionaryCodec.decode(encoded), terms)
    }

    func test_toleratesMalformedFile() {
        let malformed = "\n# a comment\n  Sotto  \n\n\nQwen3\n   \n"
        XCTAssertEqual(DictionaryCodec.decode(malformed), [DictionaryTerm("Sotto"), DictionaryTerm("Qwen3")])
    }

    func test_heardAsLinesRoundTripVerbatim() {
        let file = "Sotto (soto)\nQwen3 (quinn three, quen three)\nFoo (bar\n"
        let terms = DictionaryCodec.decode(file)
        XCTAssertEqual(DictionaryCodec.encode(terms), file)
        XCTAssertEqual(terms.map(\.heardAs), [["soto"], ["quinn three", "quen three"], []])
    }

    func test_emptyRoundTrip() {
        XCTAssertEqual(DictionaryCodec.decode(DictionaryCodec.encode([])), [])
    }
}
