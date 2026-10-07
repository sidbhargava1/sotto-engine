// The "utterance completed" hook contract (open-core ADR §1): the session gathers both context
// probes and builds the record; the recorder's gate decides. Policy itself is tested in
// SottoInsightsTests (HistoryTests, HI-).
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class HistoryRecordingHookTests: SessionTestCase {
    private func dictate(_ h: Harness) async {
        await runUtterance(h)
    }

    func test_noHistorySkipsTheSecureProbeAndIsNeverAsked() async {
        let provider = FakeContextProvider(makeTestContext())
        await dictate(makeHarness(context: provider))
        let probes = await provider.probes
        XCTAssertEqual(probes, [false], "G1: no recorder, no subrole probe")
    }

    func test_aRecorderThatWantsNothingIsNeverOffered() async {
        let hook = RecordingHistory(wants: false)
        let provider = FakeContextProvider(makeTestContext())
        await dictate(makeHarness(context: provider, history: hook))
        let probes = await provider.probes
        XCTAssertEqual(probes, [false])
        XCTAssertTrue(hook.offers.isEmpty)
        XCTAssertTrue(hook.records.isEmpty)
    }

    func test_offerCarriesReleaseContextPressAppAndPressTimeSettings() async {
        var settings = Settings()
        settings.cleanupEngine = .raw
        let hook = RecordingHistory()
        let release = makeTestContext(bundleID: "com.example.release")
        let provider = FakeContextProvider(release, pressApp: .some("com.example.press"))
        await dictate(makeHarness(context: provider, settings: settings, history: hook))
        let probes = await provider.probes
        XCTAssertEqual(probes, [true])
        XCTAssertEqual(hook.offers, [.init(context: release, pressApp: "com.example.press", settings: settings)])
        let record = try! XCTUnwrap(hook.records.first)
        XCTAssertEqual(record.bundleID, "com.example.press", "the session passes the press app as-is; the recorder decides what it stores")
        XCTAssertEqual(record.rawText, "hello world")
        XCTAssertEqual(record.backend, "raw")
    }

    func test_gateRefusalRecordsNothing() async {
        let hook = RecordingHistory(accepts: false)
        await dictate(makeHarness(history: hook))
        XCTAssertEqual(hook.offers.count, 1)
        XCTAssertTrue(hook.records.isEmpty)
    }

    func test_secureFieldAtReleaseIsRefusedWhateverTheGateSays() async {
        let secure = TargetContext(bundleID: "com.test.app", isTerminalClass: false, elementToken: AXElementToken(1), accessibilityGranted: true, isSecureInput: true)
        let hook = RecordingHistory()
        let h = makeHarness(context: FakeContextProvider(secure), history: hook)
        await dictate(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world", "still injects")
        XCTAssertTrue(hook.offers.isEmpty)
        XCTAssertTrue(hook.records.isEmpty)
    }

    func test_fieldTurningSecureAfterLandingIsRefused() async {
        // HI-24: the second probe runs after the gate passed.
        let plain = makeTestContext()
        let secure = TargetContext(bundleID: plain.bundleID, isTerminalClass: false, elementToken: plain.elementToken, accessibilityGranted: true, isSecureInput: true)
        let hook = RecordingHistory()
        await dictate(makeHarness(context: SequencedContextProvider([plain, secure]), history: hook))
        XCTAssertEqual(hook.offers.count, 1)
        XCTAssertTrue(hook.records.isEmpty)
    }

    func test_honouredScratchFlagsTheRecord() async {
        let hook = RecordingHistory()
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world"), .text("scratch that")]), history: hook)
        await h.session.start()
        for _ in 0..<2 {
            await h.hotkey.press(); await h.hotkey.release()
            await settle(h)
        }
        XCTAssertEqual(hook.records.count, 1)
        XCTAssertEqual(hook.scratched, hook.records.map(\.id))
    }
}
