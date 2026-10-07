// PLAN §6 Phase 4 must-do: heard-as variants are rewritten in code before cleanup, because the 4B
// model's dictionary hits move with every prompt edit. The prompt-level dictionary stays as backstop.
import Foundation
import Synchronization

extension DictionaryTerm {
    /// `Sotto (soto, so toe)` -> "Sotto". A line without a well-formed trailing group is all spelling.
    public var spelling: String { parsed.spelling }

    /// `Sotto (soto, so toe)` -> ["soto", "so toe"]. Malformed groups yield no variants, never a throw.
    public var heardAs: [String] { parsed.heardAs }

    private var parsed: (spelling: String, heardAs: [String]) {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard line.hasSuffix(")"), let open = line.firstIndex(of: "(") else { return (line, []) }
        let spelling = line[..<open].trimmingCharacters(in: .whitespaces)
        let inner = line[line.index(after: open)..<line.index(before: line.endIndex)]
        guard !spelling.isEmpty, !inner.contains("("), !inner.contains(")") else { return (line, []) }
        let variants = inner.split(separator: ",")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return (spelling, variants)
    }
}

public enum DictionaryRewriter {
    /// One left-to-right pass: at each position the longest variant wins, and replaced text is
    /// never re-scanned. Matches are whole words, case-insensitive, any whitespace between words.
    public static func rewrite(_ transcript: String, terms: [DictionaryTerm]) -> String {
        guard let (rules, regex) = compiled(terms) else { return transcript }

        let source = transcript as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: transcript, range: NSRange(location: 0, length: source.length)) {
            guard let rule = (1...rules.count).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += rules[rule - 1].spelling
            cursor = match.range.location + match.range.length
        }
        return out + source.substring(from: cursor)
    }

    private struct Compiled: @unchecked Sendable {  // NSRegularExpression is immutable and thread-safe
        let terms: [DictionaryTerm]
        let rules: [(variant: String, spelling: String)]
        let regex: NSRegularExpression?
    }
    /// The dictionary rarely changes between dictations, so the last compile is reused.
    private static let cache = Mutex<Compiled?>(nil)

    private static func compiled(_ terms: [DictionaryTerm]) -> ([(variant: String, spelling: String)], NSRegularExpression)? {
        if let hit = cache.withLock({ $0 }), hit.terms == terms {
            return hit.regex.map { (hit.rules, $0) }
        }
        let rules = rules(from: terms)
        let regex = rules.isEmpty ? nil : try? NSRegularExpression(
            pattern: rules.map { "(" + pattern(for: $0.variant) + ")" }.joined(separator: "|"),
            options: [.caseInsensitive]
        )
        cache.withLock { $0 = Compiled(terms: terms, rules: rules, regex: regex) }
        return regex.map { (rules, $0) }
    }

    /// Longest first (words, then characters) so regex alternation order is the precedence; ties
    /// break alphabetically so file order never changes the outcome.
    static func rules(from terms: [DictionaryTerm]) -> [(variant: String, spelling: String)] {
        var seen = Set<String>()
        return terms
            .flatMap { term in term.heardAs.map { (variant: $0, spelling: term.spelling) } }
            .sorted { a, b in
                let wa = a.variant.split(separator: " ").count, wb = b.variant.split(separator: " ").count
                if wa != wb { return wa > wb }
                if a.variant.count != b.variant.count { return a.variant.count > b.variant.count }
                return (a.variant.lowercased(), a.spelling) < (b.variant.lowercased(), b.spelling)
            }
            .filter { seen.insert($0.variant.lowercased()).inserted }
    }

    private static func pattern(for variant: String) -> String {
        let words = variant.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        return #"(?<![\p{L}\p{N}\p{M}_])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}\p{M}_])"#
    }
}
