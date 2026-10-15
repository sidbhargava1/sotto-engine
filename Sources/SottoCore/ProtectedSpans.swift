// Protected spans: phrases the host wants replaced by fixed text that the cleanup model must never
// see or edit (a snippet, a resolved path). Matching runs on the raw transcript, after command
// matching and before the dictionary rewrite. Each hit becomes an opaque placeholder; cleanup must
// carry every placeholder through exactly once, and only then is the text swapped in. If the model
// drops, repeats or invents one, the session types the raw transcript with the text swapped in
// instead (degraded), as for any cleanup failure.
import Foundation
import Synchronization

/// A spoken phrase and the text that stands in for it. The engine knows nothing about where either
/// comes from.
public struct ProtectedPhrase: Sendable, Hashable {
    public let spoken: String
    public let text: String

    public init(spoken: String, text: String) {
        self.spoken = spoken
        self.text = text
    }
}

/// One transcript after matching: the masked text cleanup sees, and what each placeholder stands for.
public struct ProtectedText: Sendable, Equatable {
    public static let open: Character = "\u{27E6}"   // ⟦
    public static let close: Character = "\u{27E7}"  // ⟧

    /// The transcript with each hit replaced by its placeholder.
    public let masked: String
    /// Placeholders in the order they appear in `masked`.
    public let tokens: [String]
    private let texts: [String: String]
    private let spoken: [String: String]

    /// Nil when nothing matched, or when the transcript already contains the placeholder brackets
    /// (nothing could then tell a spoken bracket from ours). Matches are whole words, any case, any
    /// run of whitespace or STT punctuation between a phrase's words; the longest phrase wins at
    /// each position and replaced text is never re-scanned. A phrase with fewer than one word, or
    /// with the same words as an earlier one (case-insensitively), is ignored.
    public init?(_ transcript: String, phrases: [ProtectedPhrase]) {
        guard !transcript.contains(Self.open), !transcript.contains(Self.close),
              let (rules, regex) = Self.compiled(phrases) else { return nil }
        let source = transcript as NSString
        var out = ""
        var cursor = 0
        var tokens: [String] = []
        var texts: [String: String] = [:]
        var spoken: [String: String] = [:]
        for match in regex.matches(in: transcript, range: NSRange(location: 0, length: source.length)) {
            guard let rule = (1...rules.count).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = "\(Self.open)\(tokens.count + 1)\(Self.close)"
            tokens.append(token)
            texts[token] = rules[rule - 1].text
            spoken[token] = source.substring(with: match.range)
            out += token
            cursor = match.range.location + match.range.length
        }
        guard !tokens.isEmpty else { return nil }
        masked = out + source.substring(from: cursor)
        self.tokens = tokens
        self.texts = texts
        self.spoken = spoken
    }

    private init(masked: String, tokens: [String], texts: [String: String], spoken: [String: String]) {
        self.masked = masked
        self.tokens = tokens
        self.texts = texts
        self.spoken = spoken
    }

    /// Applies `transform` to the text between placeholders, never to a placeholder (the dictionary
    /// rewrite, which must not see a placeholder's digits as a word).
    public func mappingText(_ transform: (String) -> String) -> ProtectedText {
        var out = ""
        var rest = Substring(masked)
        while let start = rest.firstIndex(of: Self.open), let end = rest[start...].firstIndex(of: Self.close) {
            out += transform(String(rest[..<start])) + rest[start...end]
            rest = rest[rest.index(after: end)...]
        }
        return ProtectedText(masked: out + transform(String(rest)), tokens: tokens, texts: texts, spoken: spoken)
    }

    /// `text` with every placeholder replaced by its text, or nil unless each placeholder appears
    /// exactly once and no other placeholder-shaped run does (a model that dropped, repeated or
    /// invented one). One pass: inserted text is never re-scanned.
    public func restoring(_ text: String) -> String? {
        var out = ""
        var seen = Set<String>()
        var rest = Substring(text)
        while let start = rest.firstIndex(of: Self.open) {
            guard !rest[..<start].contains(Self.close) else { return nil }
            out += rest[..<start]
            guard let end = rest[start...].firstIndex(of: Self.close) else { return nil }
            let token = String(rest[start...end])
            guard let replacement = texts[token], seen.insert(token).inserted else { return nil }
            out += replacement
            rest = rest[rest.index(after: end)...]
        }
        guard !rest.contains(Self.close), seen.count == tokens.count else { return nil }
        return out + rest
    }

    /// `masked` (or any text derived from it) with the placeholders swapped in, unchecked: the
    /// raw fallback. Placeholders that are missing are simply absent.
    public func swappingIn(_ text: String) -> String {
        // One left-to-right pass like `restoring`, so inserted text that happens to contain another
        // placeholder is never re-scanned. Unknown or unterminated runs stay as they are.
        var out = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(of: Self.open) {
            out += rest[..<start]
            guard let end = rest[start...].firstIndex(of: Self.close) else { rest = rest[start...]; break }
            let token = String(rest[start...end])
            out += texts[token] ?? token
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    /// Words the speaker said in an utterance that landed as `landed`: the landed words, with each
    /// placeholder's text counted as the phrase that was spoken for it. Stats count speech, so a
    /// long inserted text does not inflate them.
    func spokenWordCount(inLanded landed: String) -> Int {
        let inserted = tokens.reduce(0) { $0 + DictationRecord.wordCount(texts[$1] ?? "") }
        let said = tokens.reduce(0) { $0 + DictationRecord.wordCount(spoken[$1] ?? "") }
        return max(0, DictationRecord.wordCount(landed) - inserted + said)
    }

    /// True when nothing is left to clean: no word apart from the placeholders and hesitation
    /// sounds. Cleanup is then skipped and the text lands as written.
    public var isOnlyProtected: Bool {
        var rest = masked
        for token in tokens { rest = rest.replacingOccurrences(of: token, with: " ") }
        return !rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { !Self.hesitations.contains($0.lowercased()) }
    }

    /// What `isOnlyProtected` text lands as: the placeholders in order, one space apart.
    var onlyText: String { tokens.joined(separator: " ") }

    private static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hm", "hmm", "mm", "mmm"]

    // MARK: matching

    private struct Compiled: @unchecked Sendable {  // NSRegularExpression is immutable and thread-safe
        let phrases: [ProtectedPhrase]
        let rules: [ProtectedPhrase]
        let regex: NSRegularExpression?
    }
    private static let cache = Mutex<Compiled?>(nil)

    private static func compiled(_ phrases: [ProtectedPhrase]) -> ([ProtectedPhrase], NSRegularExpression)? {
        if let hit = cache.withLock({ $0 }), hit.phrases == phrases { return hit.regex.map { (hit.rules, $0) } }
        let rules = rules(from: phrases)
        let regex = rules.isEmpty ? nil : try? NSRegularExpression(
            pattern: rules.map { "(" + pattern(for: $0.spoken) + ")" }.joined(separator: "|"),
            options: [.caseInsensitive]
        )
        cache.withLock { $0 = Compiled(phrases: phrases, rules: rules, regex: regex) }
        return regex.map { (rules, $0) }
    }

    /// Longest first (words, then characters), ties alphabetical, so list order never changes the outcome.
    static func rules(from phrases: [ProtectedPhrase]) -> [ProtectedPhrase] {
        var seen = Set<String>()
        return phrases
            .filter { !words($0.spoken).isEmpty }
            .sorted { a, b in
                let wa = words(a.spoken).count, wb = words(b.spoken).count
                if wa != wb { return wa > wb }
                if a.spoken.count != b.spoken.count { return a.spoken.count > b.spoken.count }
                return (a.spoken.lowercased(), a.text) < (b.spoken.lowercased(), b.text)
            }
            .filter { seen.insert(words($0.spoken).joined(separator: " ").lowercased()).inserted }
    }

    private static func words(_ phrase: String) -> [String] { phrase.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// STT punctuates inside a phrase ("my calendar, link."), so between words any run of
    /// whitespace and sentence punctuation matches. Edges are word boundaries.
    private static func pattern(for phrase: String) -> String {
        let escaped = words(phrase).map { NSRegularExpression.escapedPattern(for: $0) }
        return #"(?<![\p{L}\p{N}\p{M}_])"# + escaped.joined(separator: #"[\s,.;:!?…–—-]+"#) + #"(?![\p{L}\p{N}\p{M}_])"#
    }
}

// MARK: through cleanup

extension ProtectedText {
    /// Cleanup output with the placeholders swapped in, as one chunk at the end. While the model
    /// runs it yields empty strings, so the coalescer's stall timer still sees a live stream.
    /// Throws when a placeholder is dropped, repeated or invented (or the output is cut off), so the
    /// session's raw fallback runs: the text it falls back to already has the snippets swapped in.
    func guarding(_ source: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var text = ""
                do {
                    for try await token in source {
                        text += token
                        continuation.yield("")
                    }
                } catch CleanupError.outputCapReached {
                    return continuation.finish(throwing: CleanupError.modelFailed("protected text cut off"))
                } catch {
                    return continuation.finish(throwing: error)
                }
                // Trim before the swap: the inserted text keeps its own line ends byte for byte.
                guard let restored = restoring(InjectionText.trimLineEnds(text)) else {
                    return continuation.finish(throwing: CleanupError.modelFailed("protected text lost"))
                }
                continuation.yield(restored)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The `isOnlyProtected` path: no model, the text lands as written.
    func verbatim() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(restoring(onlyText) ?? swappingIn(onlyText))
            continuation.finish()
        }
    }
}
