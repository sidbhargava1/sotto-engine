// Raw text to append when cleanup fails mid-stream (LB-09): cleanup shortens text, so align on
// words, not characters. Best context match wins, ties to the earliest; never start mid-word.
import Foundation

public enum RawRemainder {
    public static func after(produced: String, raw: String) -> String {
        let rawWords = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let rawKeys = rawWords.map(key)
        let producedKeys = produced.split(whereSeparator: \.isWhitespace).map(key).filter { !$0.isEmpty }
        guard let last = producedKeys.last else { return raw }

        // The coalescer's timed flush can cut a word, so an unterminated last word may be partial.
        let partial = produced.last.map { $0.isLetter || $0.isNumber } ?? false
        let candidates = rawKeys.indices.filter { partial ? rawKeys[$0].hasPrefix(last) : rawKeys[$0] == last }

        let rest: [String]
        if let best = bestAlignment(candidates, rawKeys: rawKeys, producedKeys: producedKeys) {
            rest = Array(rawWords[(best + 1)...])
        } else {
            rest = rawWords
        }
        guard !rest.isEmpty else { return "" }
        let separator = produced.last?.isWhitespace ?? true ? "" : " "
        return separator + rest.joined(separator: " ")
    }

    private static func bestAlignment(_ candidates: [Int], rawKeys: [String], producedKeys: [String]) -> Int? {
        var best: (index: Int, score: Int)?
        for i in candidates {
            var score = 0
            for back in 1...3 {
                let r = i - back, p = producedKeys.count - 1 - back
                guard r >= 0, p >= 0, rawKeys[r] == producedKeys[p] else { break }
                score += 1
            }
            if best == nil || score > best!.score { best = (i, score) }
        }
        return best?.index
    }

    private static func key(_ word: some StringProtocol) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
