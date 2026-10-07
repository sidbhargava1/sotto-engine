import Foundation

public protocol DictionaryStore: Sendable {
    func load() async throws -> [DictionaryTerm]
    func save(_ terms: [DictionaryTerm]) async throws
}

/// One term per non-blank, non-`#`-comment line. Tolerant of malformed input rather than
/// throwing (PLAN §7 round-trip test).
public enum DictionaryCodec {
    public static func decode(_ contents: String) -> [DictionaryTerm] {
        contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { DictionaryTerm($0) }
    }

    public static func encode(_ terms: [DictionaryTerm]) -> String {
        terms.map(\.text).joined(separator: "\n") + (terms.isEmpty ? "" : "\n")
    }
}
