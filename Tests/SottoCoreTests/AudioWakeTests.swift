// A woken engine records from the first real audio, never hangs, and stop() waits briefly for a
// buffer (SPEC §5 step 2).
import Synchronization
import XCTest
@testable import SottoCore

final class AudioWakeTests: XCTestCase {
    /// A tap that produces `buffers` with `rms` once `after` has passed.
    private final class FakeTap: Sendable {
        private let start = ContinuousClock.now
        private let after: Duration
        private let rms: Float
        init(after: Duration, rms: Float) { (self.after, self.rms) = (after, rms) }
        func probe() -> AudioWake.Probe {
            ContinuousClock.now - start >= after ? AudioWake.Probe(buffers: 1, peakRMS: rms) : AudioWake.Probe()
        }
    }

    private func timed(_ body: () async -> AudioWake.Outcome) async -> (AudioWake.Outcome, Duration) {
        let start = ContinuousClock.now
        let outcome = await body()
        return (outcome, ContinuousClock.now - start)
    }

    func test_speechArrivesLate_waitsForIt() async {
        let tap = FakeTap(after: .milliseconds(300), rms: 0.05)
        let (outcome, elapsed) = await timed { await AudioWake.waitForInput(probe: tap.probe) }
        XCTAssertEqual(outcome, .audio)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
        XCTAssertLessThan(elapsed, .milliseconds(800))
    }

    func test_quietRoom_proceedsAfterGrace() async {
        let tap = FakeTap(after: .zero, rms: 0.0002) // a live mic, nobody talking yet
        let (outcome, elapsed) = await timed { await AudioWake.waitForInput(probe: tap.probe) }
        XCTAssertEqual(outcome, .quiet)
        XCTAssertGreaterThanOrEqual(elapsed, AudioWake.quietGrace)
        XCTAssertLessThan(elapsed, .milliseconds(600))
    }

    func test_digitalSilence_isStillTheRouteSwitching() async {
        let tap = FakeTap(after: .zero, rms: 0)
        let (outcome, elapsed) = await timed {
            await AudioWake.waitForInput(cap: .milliseconds(250), quietGrace: .milliseconds(50), probe: tap.probe)
        }
        XCTAssertEqual(outcome, .silent, "zeros from a switching HFP route must not end the wait early")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(250))
    }

    func test_digitalSilenceCheck() {
        XCTAssertTrue(AudioWake.isDigitalSilence([0, 0, 0]))
        XCTAssertFalse(AudioWake.isDigitalSilence([0, 1e-7, 0]), "a real mic's noise floor is not silence")
        XCTAssertFalse(AudioWake.isDigitalSilence([]), "no audio at all is a different failure")
        XCTAssertTrue(AudioWake.isDigitalSilence([], [0, 0]), "a banked segment alone counts")
        XCTAssertFalse(AudioWake.isDigitalSilence([0], [0.2]))
    }

    func test_noBuffersEver_capsInsteadOfHanging() async {
        let tap = FakeTap(after: .seconds(60), rms: 0.05)
        let (outcome, elapsed) = await timed { await AudioWake.waitForInput(probe: tap.probe) }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertGreaterThanOrEqual(elapsed, AudioWake.cap)
        XCTAssertLessThan(elapsed, AudioWake.cap + .milliseconds(500))
    }

    func test_stopWait_returnsOnFirstBuffer() async {
        let tap = FakeTap(after: .milliseconds(100), rms: 0.01)
        let start = ContinuousClock.now
        let got = await AudioWake.waitForBuffer { tap.probe().buffers > 0 }
        XCTAssertTrue(got)
        XCTAssertLessThan(ContinuousClock.now - start, AudioWake.stopGrace)
    }

    func test_stopWait_givesUpAtLimit() async {
        let start = ContinuousClock.now
        let got = await AudioWake.waitForBuffer { false }
        XCTAssertFalse(got)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, AudioWake.stopGrace)
    }
}
