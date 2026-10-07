// The only backend wired up in Phase 1 (SPEC §6, gated on Phase 0 R2). Still flows through
// `StreamCoalescer` like any other backend (CO-05) — purity isn't a shortcut around shared
// batching.
import Foundation

public struct RawBackend: CleanupBackend {
    public init() {}

    public func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Self.tidy(request.rawTranscript))
            continuation.finish()
        }
    }

    /// SPEC §5 step 5's "light, normalise" — whitespace only, no semantic rewriting.
    static func tidy(_ text: String) -> String {
        text
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
