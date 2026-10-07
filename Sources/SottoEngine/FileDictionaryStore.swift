// One term per line via DictionaryCodec, so a user can hand-edit it (PLAN §1 persistence).
import Foundation
import SottoCore

public actor FileDictionaryStore: DictionaryStore {
    public nonisolated let url: URL

    /// The host names the file (ADR §5).
    public init(url: URL) {
        self.url = url
    }

    public func load() async throws -> [DictionaryTerm] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return DictionaryCodec.decode(try String(contentsOf: url, encoding: .utf8))
    }

    public func save(_ terms: [DictionaryTerm]) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DictionaryCodec.encode(terms).write(to: url, atomically: true, encoding: .utf8)
    }
}
