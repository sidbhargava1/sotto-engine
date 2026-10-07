import Foundation

/// `start()` marks a buffer offset on an already-running engine (SPEC §5 step 2). Between
/// dictations the session puts the engine to `sleep()` so the mic light goes out, and `wake()`s
/// it on the next press; `start()` also cold-starts an engine stopped by Pause (ui-spec §2).
public protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async throws -> AudioBuffer
    func sleep() async
    func wake() async throws
    /// Normalised mic level (`AudioLevel`) at about 30 Hz while the caller listens; cancelling the
    /// consumer ends publishing. One subscriber at a time: a new call finishes the previous stream.
    func levels() -> AsyncStream<Float>
    /// 16 kHz mono deltas from the capture mark, about every 100 ms, for `Transcribing.partials`.
    /// One subscriber at a time, like `levels()`; `stop()` finishes it.
    func chunks() -> AsyncStream<AudioBuffer>
    /// Transport of the input the engine opens (or will open on wake); drives `AudioIdleSleep`.
    func inputTransport() async -> AudioTransport
}

/// Errors the session tells apart; anything else from `start()` reads as mic access being off.
public enum AudioCaptureError: Error, Equatable {
    /// No input device at all (Mac mini, lid closed with no external mic).
    case noInput
    /// The engine is stopped (a restart failed mid-flap); the next press cold-starts it.
    case engineNotRunning
}

extension AudioCapturing {
    public func sleep() async {}
    public func wake() async throws {}
    public func levels() -> AsyncStream<Float> { AsyncStream { $0.finish() } }
    public func chunks() -> AsyncStream<AudioBuffer> { AsyncStream { $0.finish() } }
    public func inputTransport() async -> AudioTransport { .other }
}

/// How long the engine stays warm after a dictation (SPEC §5 step 2): long enough that a
/// back-to-back press keeps its pre-roll, short enough that the mic light goes out promptly.
public enum AudioIdleSleep {
    public static let grace: Duration = .seconds(2)

    /// nil: never sleep. Waking a Bluetooth mic renegotiates HFP (hundreds of ms to seconds),
    /// so it stays warm and the mic light stays on while Sotto runs (SPEC §12).
    public static func grace(for transport: AudioTransport, standard: Duration = grace) -> Duration? {
        transport == .bluetooth ? nil : standard
    }
}
