import Foundation

/// Batch for MVP (PLAN §2); streamed shape so a streaming adapter drops in later without
/// touching `DictationSession`.
public protocol Transcribing: Sendable {
    func transcribe(_ buffer: AudioBuffer) -> AsyncThrowingStream<TranscriptChunk, Error>

    /// Display-only partials while the key is held (spikes/stream/RESULTS.md). `audio` yields 16 kHz
    /// mono deltas from the capture mark. The consumer cancels on release; the adapter must stop
    /// ANE work promptly so the final `transcribe(_:)` isn't queued behind it. Never feeds commands
    /// or cleanup, and never logged.
    func partials(_ audio: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<PartialTranscript, Error>

    /// The engine one utterance uses for both `partials` and the final `transcribe`, resolved at
    /// press so a Settings switch mid-hold can't split them (SwitchingTranscriber).
    func engineForUtterance() -> any Transcribing
}

extension Transcribing {
    /// Batch-only engines: finish immediately and the bubble waits for the transcript (ui-spec §1.6).
    public func partials(_ audio: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<PartialTranscript, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public func engineForUtterance() -> any Transcribing { self }
}
