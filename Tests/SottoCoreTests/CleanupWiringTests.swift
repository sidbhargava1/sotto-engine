// Phase 2 session-side scenarios, docs/phase2-test-scenarios.md (LB-/WR- ids).
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

final class CleanupWiringTests: SessionTestCase {
    private func states(_ h: Harness) async -> StateLog { await collectStates(h) }

    // MARK: WR-02 — the raw engine (cleanup off) never asks the model

    func test_WR02_rawEngineNeverCallsTheModel() async {
        let backend = FixtureBackend(steps: [.init("MODEL")])
        let h = makeHarness(backend: backend)
        await h.settings.update { $0.cleanupEngine = .raw }
        await runUtterance(h)
        let calls = await backend.calls
        XCTAssertEqual(calls, 0)
    }

    // MARK: WR-03/LB-11 — model not ready: raw at once, degraded, no 1.5s wait

    func test_WR03_notReadyTypesRawImmediately() async {
        let backend = FixtureBackend(steps: [], ending: .fail(CleanupError.notReady))
        let h = makeHarness(backend: backend, coalescerConfig: CoalescerConfig(flushInterval: .milliseconds(20), firstTokenTimeout: .seconds(5), stallTimeout: .seconds(5)))
        let log = await states(h)
        let start = ContinuousClock.now
        await runUtterance(h)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
        let settled = await log.settled()
        XCTAssertTrue(settled.contains(.degraded(.rawTyped)), "\(settled)")
    }

    // MARK: WR-04 — a toggle mid-hold applies from the next press

    func test_WR04_toggleMidHoldKeepsThePressTimeBackend() async {
        let backend = FixtureBackend(steps: [.init("Cleaned.")])
        let h = makeHarness(backend: backend)
        await h.session.start()
        await h.hotkey.press()
        await settle(h)
        await h.settings.update { $0.cleanupEngine = .raw }
        await h.hotkey.release()
        await settle(h)
        await h.hotkey.press()
        await h.hotkey.release()
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "Cleaned.hello world")
    }

    // MARK: LB-05 — an empty or whitespace-only answer types raw, degraded

    func test_LB05_noChunksTypesRawDegraded() async {
        let h = makeHarness(backend: FixtureBackend(steps: []))
        let log = await states(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
        let settled = await log.settled()
        XCTAssertTrue(settled.contains(.degraded(.rawTyped)), "\(settled)")
    }

    func test_LB05_whitespaceOnlyAnswerTypesRaw() async {
        let h = makeHarness(backend: FixtureBackend(steps: [.init("  "), .init("\n")]))
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertTrue(injected.hasSuffix("hello world"), injected)
    }

    func test_LB05_emptyAnswerToClipboardCopiesRaw() async {
        let context = FakeContextProvider(makeTestContext(bundleID: nil, hasTarget: false))
        let h = makeHarness(backend: FixtureBackend(steps: []), context: context)
        await runUtterance(h)
        let copied = await h.clipboard.copied
        XCTAssertEqual(copied, ["hello world"])
    }

    // MARK: LB-06 — output cap: keep what's typed, degraded, no raw append

    func test_LB06_outputCapKeepsTypedAndAppendsNothing() async {
        let backend = FixtureBackend(steps: [.init("Hello there ")], ending: .fail(CleanupError.outputCapReached))
        let h = makeHarness(backend: backend)
        let log = await states(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "Hello there ")
        let settled = await log.settled()
        XCTAssertTrue(settled.contains(.degraded(.cleanupTruncated)), "\(settled)")
    }

    // MARK: LB-08 — a stall cancels the decode; the next utterance isn't queued behind it

    func test_LB08_stallCancelsTheBackendStream() async {
        let backend = FixtureBackend(steps: [.init("late", after: .seconds(5))])
        let h = makeHarness(backend: backend, coalescerConfig: CoalescerConfig(flushInterval: .milliseconds(20), firstTokenTimeout: .milliseconds(60), stallTimeout: .milliseconds(60)))
        await runUtterance(h)
        await waitUntil("the backend's cancellation") { await backend.cancellations > 0 }
        let cancellations = await backend.cancellations
        XCTAssertEqual(cancellations, 1)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
    }

    // MARK: first-token timeout — a backend that never yields still gets the words typed

    func test_backendThatNeverYieldsTypesRawDegraded() async {
        let backend = FixtureBackend(steps: [.init("never", after: .seconds(30))])
        let h = makeHarness(backend: backend, coalescerConfig: CoalescerConfig(flushInterval: .milliseconds(20), firstTokenTimeout: .milliseconds(80), stallTimeout: .milliseconds(80)))
        let log = await states(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
        let settled = await log.settled()
        XCTAssertEqual(settled.suffix(2), [.degraded(.rawTyped), .idle])
    }

    // MARK: LB-09 — mid-stream failure resumes on a word, not a character count

    func test_LB09_throwMidStreamAppendsFromTheNextRawWord() async {
        let transcriber = FixtureTranscriber([.text("um so send it tuesday no wait wednesday to the team")])
        let backend = FixtureBackend(steps: [.init("Send it Wednesday ")], ending: .fail(FakeError(label: "boom")))
        let h = makeHarness(transcriber: transcriber, backend: backend)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "Send it Wednesday to the team")
    }

    // MARK: latency line — one report per dictation

    func test_timingReportedOncePerDictation() async {
        let reports = TimingLog()
        let hotkey = FakeHotkeyMonitor()
        let ax = RecordingInjector()
        let session = DictationSession(
            hotkey: hotkey, audio: FixtureAudioCapture(), transcriber: FixtureTranscriber([.text("one two three")]),
            cleanup: FixtureBackend(steps: [.init("One two three.")]),
            injectors: InjectorChain(ax: ax, paste: RecordingInjector(), unicode: RecordingInjector()),
            contextProvider: FakeContextProvider(makeTestContext()), dictionaryStore: InMemoryDictionaryStore(),
            settingsStore: InMemorySettings(), clipboard: FakeClipboard(), undo: FakeUndo(),
            coalescerConfig: SessionTestCase.patientCoalescer,
            onTiming: { reports.append($0) }
        )
        await session.start()
        await hotkey.press()
        await hotkey.release()
        await session.drain(handled: 2)
        let all = reports.snapshot()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.words, 3)
        XCTAssertNotNil(all.first?.releaseToFirstInject)
        XCTAssertNotNil(all.first?.ttft)
    }
}

final class TimingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [UtteranceTiming] = []
    func append(_ r: UtteranceTiming) { lock.withLock { reports.append(r) } }
    func snapshot() -> [UtteranceTiming] { lock.withLock { reports } }
}
