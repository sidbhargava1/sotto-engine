import Foundation

/// Receives the raw transcript of a diverted utterance (`HotkeyEvent.divert`) in place of command
/// matching, cleanup, injection and history. The transcript is trimmed STT output, never empty.
///
/// Call contract: calls may overlap (a later utterance can finish before an earlier one's call
/// returns) and arrive in no guaranteed order, so a sink that cares must order by `clock`. The
/// session awaits each call: a slow `receive` or `failed` delays idle sleep of the audio engine
/// and `drain`, so hand work off rather than doing it inline.
public protocol UtteranceSink: Sendable {
    func receive(_ rawTranscript: String, clock: UtteranceClock) async
    /// A diverted utterance ended without a transcript (no speech, STT failure, model missing,
    /// lost mic). The session has already emitted the matching `.error` and `.idle`.
    func failed(_ reason: ErrorReason, clock: UtteranceClock) async
}

extension UtteranceSink {
    public func failed(_ reason: ErrorReason, clock: UtteranceClock) async {}
}
