// The engine sleeps a grace period after each dictation so the mic light goes out (SPEC §5 step 2).
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class IdleSleepTests: SessionTestCase {
    private let grace: Duration = .milliseconds(60)

    func test_releaseThenIdle_sleepsAfterGrace() async {
        let h = makeHarness(idleSleepGrace: grace)
        await runUtterance(h)
        var calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop"], "must stay warm during the grace period")
        try? await Task.sleep(for: grace * 3)
        calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "sleep"])
    }

    func test_pressWithinGrace_cancelsSleep() async {
        let h = makeHarness(idleSleepGrace: .milliseconds(200))
        await runUtterance(h)
        await h.hotkey.press()
        await settle(h)
        try? await Task.sleep(for: .milliseconds(400))
        let calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "start"], "a held key must never be slept under")
    }

    func test_pressAfterSleep_wakesThenRecords() async {
        let h = makeHarness(idleSleepGrace: grace)
        await runUtterance(h)
        try? await Task.sleep(for: grace * 3)
        await h.hotkey.press()
        await h.hotkey.release()
        await settle(h)
        let calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "sleep", "wake", "start", "stop"])
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected.components(separatedBy: "hello world").count - 1, 2, "the woken press must still deliver its utterance")
    }

    func test_pressDuringSleep_waitsThenWakes() async {
        let h = makeHarness(idleSleepGrace: grace)
        await h.audio.holdNextSleep()
        await runUtterance(h)
        while await !h.audio.calls.contains("sleep") { try? await Task.sleep(for: .milliseconds(5)) }
        await h.hotkey.press()
        try? await Task.sleep(for: .milliseconds(50))
        var calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "sleep"], "wake must not overtake an unfinished sleep")
        await h.audio.openSleepGate()
        await settle(h)
        calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "sleep", "wake", "start"])
    }

    func test_idleSleepNeverTouchesPause() async {
        let h = makeHarness(idleSleepGrace: grace)
        await runUtterance(h)
        try? await Task.sleep(for: grace * 3)
        let paused = await h.settings.load().paused
        XCTAssertFalse(paused, "auto-sleep is not the user-facing Pause toggle")
    }

    // MARK: transport policy — Bluetooth stays warm (SPEC §12)

    func test_graceByTransport() {
        XCTAssertEqual(AudioIdleSleep.grace(for: .builtIn), .seconds(2))
        XCTAssertEqual(AudioIdleSleep.grace(for: .usb), .seconds(2))
        XCTAssertEqual(AudioIdleSleep.grace(for: .other), .seconds(2))
        XCTAssertNil(AudioIdleSleep.grace(for: .bluetooth))
    }

    func test_bluetoothInput_neverSleeps() async {
        let h = makeHarness(idleSleepGrace: grace)
        await h.audio.setTransport(.bluetooth)
        await runUtterance(h)
        try? await Task.sleep(for: grace * 4)
        let calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop"], "waking a Bluetooth mic costs the HFP switch")
    }

    func test_bluetoothThenBuiltIn_reschedulesSleep() async {
        let h = makeHarness(idleSleepGrace: grace)
        await h.audio.setTransport(.bluetooth)
        await runUtterance(h)
        await h.audio.setTransport(.builtIn)
        await h.session.scheduleIdleSleep() // what the app does on a device change
        try? await Task.sleep(for: grace * 3)
        let calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "sleep"])
    }

    func test_backToBackOnBluetooth_neverWakes() async {
        let h = makeHarness(idleSleepGrace: grace)
        await h.audio.setTransport(.bluetooth)
        await runUtterance(h)
        try? await Task.sleep(for: grace * 3)
        await h.hotkey.press()
        await h.hotkey.release()
        await settle(h)
        let calls = await h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "start", "stop"])
    }
}
