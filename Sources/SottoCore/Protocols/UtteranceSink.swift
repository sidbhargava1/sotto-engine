import Foundation

/// Receives the raw transcript of a diverted utterance (`HotkeyEvent.divert`) in place of command
/// matching, cleanup, injection and history. The transcript is trimmed STT output, never empty.
public protocol UtteranceSink: Sendable {
    func receive(_ rawTranscript: String, clock: UtteranceClock) async
}
