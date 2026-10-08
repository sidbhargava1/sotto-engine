import Foundation

/// Timestamps for one utterance's latency line and history row. Written from the delivery task
/// and the first-token relay, hence the lock.
final class UtteranceClock: @unchecked Sendable {
    private let lock = NSLock()
    private let releasedAt: ContinuousClock.Instant
    private let pressedAt: ContinuousClock.Instant
    /// Wall clock at hotkey down: the row's `started_at` (SPEC §15.2).
    let startedAt: Date
    private var _sttDone: ContinuousClock.Instant?
    private var firstToken: ContinuousClock.Instant?
    private var firstInject: ContinuousClock.Instant?
    private var landedAt: ContinuousClock.Instant?

    init(pressedAt: ContinuousClock.Instant, startedAt: Date, releasedAt: ContinuousClock.Instant) {
        self.pressedAt = pressedAt
        self.startedAt = startedAt
        self.releasedAt = releasedAt
    }

    var sttDone: ContinuousClock.Instant? {
        get { lock.withLock { _sttDone } }
        set { lock.withLock { _sttDone = newValue } }
    }

    func markFirstToken(_ at: ContinuousClock.Instant) { lock.withLock { if firstToken == nil { firstToken = at } } }

    func markInjected(_ at: ContinuousClock.Instant) {
        lock.withLock {
            if firstInject == nil { firstInject = at }
            landedAt = at
        }
    }

    /// Clipboard deliveries land when copied (HI-42) but aren't an injection.
    func markLanded(_ at: ContinuousClock.Instant) { lock.withLock { landedAt = at } }

    func report(end: ContinuousClock.Instant, words: Int) -> UtteranceTiming {
        lock.withLock {
            let stt = _sttDone ?? releasedAt
            return UtteranceTiming(
                releaseToFirstInject: firstInject.map { $0 - releasedAt },
                stt: stt - releasedAt,
                ttft: firstToken.map { $0 - stt },
                total: end - releasedAt,
                words: words
            )
        }
    }

    /// Row timings: stt + cleanup = landed, all from release; `held` is press → release.
    func rowTimings(end: ContinuousClock.Instant) -> (held: Int, stt: Int, cleanup: Int, landed: Int) {
        lock.withLock {
            let stt = _sttDone ?? releasedAt
            let landed = landedAt ?? end
            return (Self.ms(releasedAt - pressedAt), Self.ms(stt - releasedAt), Self.ms(landed - stt), Self.ms(landed - releasedAt))
        }
    }

    private static func ms(_ d: Duration) -> Int { Int((d / .milliseconds(1)).rounded()) }
}
