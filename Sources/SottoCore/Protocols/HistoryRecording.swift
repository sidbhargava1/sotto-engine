import Foundation

/// The session's "utterance completed" hook (open-core ADR §1). The session gathers context and
/// builds the record; the recorder owns the policy. Synchronous and non-awaiting so recording can
/// never sit on the release→landed path; implementations queue and return.
public protocol HistoryRecording: Sendable {
    /// Asked once per utterance with the press-time settings snapshot. False means nothing from it
    /// can be recorded, so the session skips the secure-field probe (up to 250ms, G1).
    func wantsRecords(_ settings: Settings) -> Bool
    /// The recorder's gate, after landing. `context` is the raw release-time read and `pressApp`
    /// the hotkey-down app. Secure fields are refused by the session regardless (both probes).
    func shouldRecord(context: TargetContext, pressApp: String?, settings: Settings) -> Bool
    func record(_ record: DictationRecord)
    /// True when `pressApp` or `context` is an app the user excluded from remembering. Asked after
    /// every landing, History on or off, because the engine's in-memory last landing (replace,
    /// Copy Last) obeys the same exclusions. The default is false: a host with exclusions must
    /// implement it.
    func isExcluded(context: TargetContext, pressApp: String?, settings: Settings) -> Bool
    /// Only after an honoured ⌘Z (SPEC §9); `id` may name a record that was never written.
    func markScratched(_ id: UUID)
}

extension HistoryRecording {
    public func isExcluded(context: TargetContext, pressApp: String?, settings: Settings) -> Bool { false }
}

/// `--dry-run` and tests that don't care: wants nothing, so the secure probe never runs.
public struct NoHistory: HistoryRecording {
    public init() {}
    public func wantsRecords(_ settings: Settings) -> Bool { false }
    public func shouldRecord(context: TargetContext, pressApp: String?, settings: Settings) -> Bool { false }
    public func record(_ record: DictationRecord) {}
    public func markScratched(_ id: UUID) {}
}
