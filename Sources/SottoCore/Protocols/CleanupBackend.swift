import Foundation

/// Streamed from Phase 1 on so injection can start on time-to-first-character, not completion
/// (PLAN §3 consequence 1) — not retrofittable, per CLAUDE.md.
public protocol CleanupBackend: Sendable {
    func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error>
}
