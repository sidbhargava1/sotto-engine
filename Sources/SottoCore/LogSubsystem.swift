import os

/// Where engine code logs (ADR §5): the host names the unified-log subsystem, so nothing in the
/// engine hard-codes one. Categories ("session", "stt", "llm", …) stay fixed across hosts.
public struct LogSubsystem: Sendable, Hashable {
    public let name: String

    public init(_ name: String) { self.name = name }

    /// For hosts and tests that don't route engine logs anywhere in particular.
    public static let engine = LogSubsystem("sotto-engine")

    public func logger(_ category: String) -> Logger { Logger(subsystem: name, category: category) }
}
