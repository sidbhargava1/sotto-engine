import Foundation

/// A woken engine is not a live mic: a Bluetooth input spends its HFP route switch delivering
/// nothing or digital silence. The adapter polls its tap through these before marking or
/// snapshotting, so the press records from the first real audio (SPEC §5 step 2).
public enum AudioWake {
    /// About -60 dBFS: above any route-switch silence, below every real mic's noise floor.
    public static let audioFloor: Float = 0.001
    /// After this, any non-zero buffer counts: the route is up, the user just isn't speaking.
    public static let quietGrace: Duration = .milliseconds(150)
    /// Never hang a press: past this the recording starts anyway ("Didn't catch that" at worst).
    public static let cap: Duration = .milliseconds(1500)
    /// stop() waits this long for one buffer after the mark, so a quick tap isn't empty.
    public static let stopGrace: Duration = .milliseconds(300)

    /// Tap buffers since the probe was armed, and the loudest buffer RMS among them.
    public struct Probe: Sendable, Equatable {
        public var buffers: Int
        public var peakRMS: Float
        public init(buffers: Int = 0, peakRMS: Float = 0) {
            self.buffers = buffers
            self.peakRMS = peakRMS
        }
    }

    /// `silent`: timed out on buffers of exact digital zeros, an input that is open but delivers
    /// nothing (a flapping HFP route). Still records: display only (SessionState "No audio from").
    public enum Outcome: Sendable, Equatable { case audio, quiet, timedOut, silent }

    public static func waitForInput(
        cap: Duration = cap,
        quietGrace: Duration = quietGrace,
        poll: Duration = .milliseconds(5),
        probe: @Sendable () -> Probe
    ) async -> Outcome {
        let start = ContinuousClock.now
        while true {
            let p = probe()
            if p.buffers > 0, p.peakRMS > audioFloor { return .audio }
            let elapsed = ContinuousClock.now - start
            if p.buffers > 0, p.peakRMS > 0, elapsed >= quietGrace { return .quiet }
            if elapsed >= cap || Task.isCancelled { return p.buffers > 0 && p.peakRMS == 0 ? .silent : .timedOut }
            try? await Task.sleep(for: poll)
        }
    }

    /// A recording that is all exact zeros: the input was open but delivered nothing. Real mics
    /// never produce this, even in a silent room (their noise floor is above zero).
    /// Takes the recording in parts (banked segments, then the live one) to avoid a copy.
    public static func isDigitalSilence(_ parts: [Float]...) -> Bool {
        parts.contains { !$0.isEmpty } && parts.allSatisfy { $0.allSatisfy { $0 == 0 } }
    }

    /// True once `hasAudio` holds, false if `limit` passes first.
    public static func waitForBuffer(
        limit: Duration = stopGrace,
        poll: Duration = .milliseconds(5),
        hasAudio: @Sendable () -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while !hasAudio() {
            if ContinuousClock.now - start >= limit || Task.isCancelled { return false }
            try? await Task.sleep(for: poll)
        }
        return true
    }
}
