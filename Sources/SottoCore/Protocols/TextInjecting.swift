import Foundation

/// One strategy per adapter (AX / paste / unicode); `DictationSession` owns the fallback chain.
public protocol TextInjecting: Sendable {
    func append(_ text: String, to context: TargetContext) async -> InjectionOutcome
}

/// Not in PLAN §4's table — "no editable target -> clipboard" (SPEC §5 step 9) needs
/// `NSPasteboard`, which SottoCore can't import. Deviation, flagged in the Phase 1 report.
public protocol ClipboardWriting: Sendable {
    func copy(_ text: String) async
}
