// Matches BEFORE cleanup, on the raw transcript (CLAUDE.md) — cleanup would rewrite or drop
// "scratch that" as a false start.
import Foundation

public enum CommandParser {
    /// STT renderings of "scratch that" seen in daily use (Parakeet: "scrap stat").
    static let scratchVariants: Set<String> = [
        "scratch that", "scratch that out", "scratch it", "scrap that",
        "scrap stat", "scratch dat", "scratched that", "scratch at",
    ]

    /// Within the fuzzy rule's reach but plausible things to dictate on their own.
    static let fuzzyRejects: Set<String> = ["scratch test", "scrape that"]

    /// Whole-utterance only, <= 4 words after normalising — "scratch that thought" must NOT
    /// match (DS-18); near-misses go through as ordinary dictation.
    public static func parse(_ rawTranscript: String) -> Command? {
        let normalized = normalize(rawTranscript)
        let words = normalized.split(separator: " ")
        guard words.count <= 4 else { return nil }
        if scratchVariants.contains(normalized) { return .scratchThat }
        return isFuzzyScratchThat(normalized, words: words) ? .scratchThat : nil
    }

    /// Edit distance alone (<= 3) would also accept "scratch the", "catch that" and "watch that",
    /// so the fuzzy rule also anchors on the "scr" onset and the closing /t/ of "that".
    static func isFuzzyScratchThat(_ normalized: String, words: [Substring]) -> Bool {
        guard !fuzzyRejects.contains(normalized), (2...3).contains(words.count),
              let first = words.first, first.hasPrefix("scr"),
              let last = words.last, last.hasSuffix("t")
        else { return false }
        return damerauLevenshtein(normalized, "scratch that") <= 3
    }

    static func wordCount(_ rawTranscript: String) -> Int {
        normalize(rawTranscript).split(separator: " ").count
    }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars
            .filter { !CharacterSet.punctuationCharacters.contains($0) }
            .map(Character.init)
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Optimal-string-alignment variant: adjacent transpositions count as one edit.
    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        guard !s.isEmpty else { return t.count }
        guard !t.isEmpty else { return s.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: t.count + 1), count: s.count + 1)
        for i in 0...s.count { d[i][0] = i }
        for j in 0...t.count { d[0][j] = j }
        for i in 1...s.count {
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[s.count][t.count]
    }
}
