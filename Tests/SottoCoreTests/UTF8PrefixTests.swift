import XCTest
@testable import SottoCore

final class UTF8PrefixTests: XCTestCase {
    /// Feeds `text` in `split`-byte pieces the way tokens arrive, decoding only complete prefixes.
    private func stream(_ text: String, split: Int) -> String {
        var pending: [UInt8] = [], out = ""
        let bytes = Array(text.utf8)
        for i in stride(from: 0, to: bytes.count, by: split) {
            pending += bytes[i..<min(i + split, bytes.count)]
            let n = UTF8Prefix.completeLength(pending)
            out += String(decoding: pending.prefix(n), as: UTF8.self)
            pending.removeFirst(n)
        }
        XCTAssertTrue(pending.isEmpty)
        return out
    }

    func test_twoThreeAndFourByteCharactersSplitAcrossTokens() {
        for text in ["café", "naïve — ok", "日本語", "ship it 🎉🚀", "a\u{0301}"] {
            for split in 1...4 { XCTAssertEqual(stream(text, split: split), text, "\(text) split \(split)") }
        }
    }

    func test_holdsAnIncompleteTail() {
        let euro = Array("€".utf8)  // 3 bytes
        XCTAssertEqual(UTF8Prefix.completeLength(Array("a".utf8) + euro.prefix(2)), 1)
        let emoji = Array("🎉".utf8)  // 4 bytes
        XCTAssertEqual(UTF8Prefix.completeLength(emoji.prefix(3) + []), 0)
        XCTAssertEqual(UTF8Prefix.completeLength(emoji), 4)
        XCTAssertEqual(UTF8Prefix.completeLength([]), 0)
    }
}
