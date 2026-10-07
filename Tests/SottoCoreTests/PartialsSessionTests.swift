// DictationSession wiring for live partials (PLAN §6 Phase 6; spikes/stream/RESULTS.md "Frame
// budget" and "Requirements for the wiring PR"). Fakes only.
import OSLog
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

final class PartialsSessionTests: SessionTestCase {
    private func snapshot(_ text: String, _ seconds: Double = 1) -> PartialTranscript {
        PartialTranscript(stable: text, volatile: "", audioSeconds: seconds)
    }

    private func collectPartials(_ h: Harness) async -> PartialLog {
        let log = PartialLog()
        let stream = await h.session.partialUpdates()
        Task { for await p in stream { log.append(p) } }
        return log
    }

    /// Polls an EventLog; the fakes record from their own tasks.
    private func waitFor(_ event: String, in log: EventLog<String>, timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while !log.snapshot().contains(event), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(log.snapshot().contains(event), "never saw \(event)")
    }

    private func waitForCount(_ log: PartialLog, _ n: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while log.snapshot().count < n, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func test_startsAtCaptureMark_cancelsBeforeStop_finalAfter() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber(partials: .hang, events: events), audio: audio)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitFor("partials.inFlight", in: events)
        await h.hotkey.release()
        await settle(h)

        let log = events.snapshot()
        XCTAssertEqual(log.filter { $0 != "partials.inFlight" }, ["audio.chunks", "partials.start", "partials.cancelled", "audio.stop", "transcribe"])
        let calls = await audio.calls
        XCTAssertEqual(Array(calls.prefix(2)), ["start", "stop"], "chunks subscribe after the capture mark")
    }

    func test_publishesWhileRecording_nilAtRelease() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let p1 = snapshot("so I think"), p2 = PartialTranscript(stable: "so I think we", volatile: "should", audioSeconds: 1.6)
        let h = makeHarness(transcriber: FixtureTranscriber(partials: .perChunk([p1, p2]), events: events), audio: audio)
        let partials = await collectPartials(h)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        audio.pushChunk()
        await waitForCount(partials, 2)
        await h.hotkey.release()
        await settle(h)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(partials.snapshot(), [p1, p2, nil])
    }

    func test_shortTap_onlyClearsAndFinalLands() async {
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world")], partials: .perChunk([snapshot("junk")])))
        let partials = await collectPartials(h)
        await runUtterance(h)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(partials.snapshot(), [nil])
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
    }

    func test_partialStreamError_clearsBubble_finalStillLands() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world")], partials: .fail(FakeError(label: "ane")), events: events), audio: audio)
        let partials = await collectPartials(h)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        XCTAssertEqual(partials.snapshot(), [nil], "a failed engine stream clears the bubble")
        await h.hotkey.release()
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
    }

    func test_sttFailureAfterPartials_bubbleEndsCleared() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber([.fail(FakeError(label: "stt"))], partials: .perChunk([snapshot("hello")]), events: events), audio: audio)
        let partials = await collectPartials(h)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await settle(h)
        XCTAssertEqual(partials.snapshot().last, .some(nil))
        let all = await states.settled()
        XCTAssertTrue(all.contains(.error(.sttFailed)))
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "")
    }

    func test_batchOnlyEngine_publishesPlaceholderOnly() async {
        let h = makeHarness() // FixtureTranscriber defaults to the protocol's batch-only partials
        let partials = await collectPartials(h)
        await h.session.start()
        await h.hotkey.press()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await settle(h)
        XCTAssertEqual(partials.snapshot(), [nil])
    }

    func test_livePartialsOff_neverSubscribesToChunks() async {
        let events = EventLog<String>()
        let h = makeHarness(transcriber: FixtureTranscriber(partials: .hang, events: events), audio: FixtureAudioCapture(events: events), livePartials: false)
        await runUtterance(h)
        XCTAssertEqual(events.snapshot(), ["audio.stop", "transcribe"])
    }

    func test_maxDurationCap_cancelsPartialsBeforeStop() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber(partials: .hang, events: events), audio: audio, maxRecordingDuration: .milliseconds(100))
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitFor("transcribe", in: events)
        await h.hotkey.release() // stray release after the cap: ignored
        await settle(h)
        let log = events.snapshot().filter { $0 != "partials.inFlight" }
        XCTAssertEqual(log, ["audio.chunks", "partials.start", "partials.cancelled", "audio.stop", "transcribe"])
    }

    func test_engineResolvedAtPress_usedForPartialsAndFinal() async {
        let a = FixtureTranscriber([.text("from a")], partials: .perChunk([snapshot("a")]))
        let b = FixtureTranscriber([.text("from b")], partials: .perChunk([snapshot("b")]))
        let switching = PinnedSwitch(a)
        let audio = FixtureAudioCapture()
        let h = makeHarness(transcriber: FixtureTranscriber(), audio: audio)
        let session = DictationSession(
            hotkey: h.hotkey, audio: audio, transcriber: switching, cleanup: RawBackend(),
            injectors: InjectorChain(ax: h.ax, paste: h.paste, unicode: h.unicode), contextProvider: h.context,
            dictionaryStore: InMemoryDictionaryStore(), settingsStore: h.settings, clipboard: h.clipboard, undo: h.undo
        )
        let partials = PartialLog()
        let stream = await session.partialUpdates()
        Task { for await p in stream { partials.append(p) } }
        await session.start()
        await h.hotkey.press()
        try? await Task.sleep(for: .milliseconds(20))
        switching.select(b) // Settings change mid-hold applies from the next utterance
        audio.pushChunk()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await session.drain(handled: 2)
        XCTAssertEqual(partials.snapshot().first, .some(snapshot("a")))
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "from a")
    }

    // MARK: display gate (mascot-concept §2; Classic runs no partials)

    func test_gateClosed_noPartialsNoRawSnapshot() async {
        let events = EventLog<String>()
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world")], partials: .hang, events: events), audio: FixtureAudioCapture(events: events), displayGate: { false })
        let raw = RawLog()
        let stream = await h.session.rawTranscriptUpdates()
        Task { for await text in stream { raw.append(text) } }
        await runUtterance(h)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(events.snapshot(), ["audio.stop", "transcribe"])
        XCTAssertEqual(raw.snapshot(), [])
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
    }

    func test_gateOpen_rawSnapshotOnceAfterSTT() async {
        let h = makeHarness(transcriber: FixtureTranscriber([.text(" hello world ")]))
        let raw = RawLog()
        let stream = await h.session.rawTranscriptUpdates()
        Task { for await text in stream { raw.append(text) } }
        await runUtterance(h)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(raw.snapshot(), ["hello world"])
    }

    func test_gateAskedOncePerPress() async {
        let asks = RawLog()
        let h = makeHarness(displayGate: { asks.append("ask"); return true })
        await runUtterance(h)
        await runUtterance(h)
        XCTAssertEqual(asks.snapshot().count, 2)
    }

    // MARK: display-only proof

    /// The bubble may show "scratch that"; only the final transcript may reach CommandParser and
    /// cleanup, and no partial text may reach the log.
    func test_partialsAreDisplayOnly() async throws {
        let since = Date()
        let junk = "scratch that zqxjunkword"
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let backend = RecordingCleanup()
        let h = makeHarness(
            transcriber: FixtureTranscriber([.text("hello world")], partials: .perChunk([snapshot(junk), snapshot("scratch that")]), events: events),
            backend: backend, audio: audio
        )
        let partials = await collectPartials(h)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        audio.pushChunk()
        await waitForCount(partials, 2)
        await h.hotkey.release()
        await settle(h)

        XCTAssertEqual(partials.snapshot().first, .some(snapshot(junk)))
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.rawTranscript), ["hello world"])
        let undos = await h.undo.callCount()
        XCTAssertEqual(undos, 0, "a partial 'scratch that' must never become a command")
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: since), matching: NSPredicate(format: "subsystem == %@", LogSubsystem.engine.name))
            .compactMap { $0 as? OSLogEntryLog }.map(\.composedMessage)
        guard entries.contains(where: { $0.hasPrefix("command: none") }) else {
            throw XCTSkip("this process's log store isn't readable here")
        }
        // Unique token only: other tests in this process legitimately log "matched scratchThat".
        XCTAssertFalse(entries.contains { $0.contains("zqxjunkword") })
    }

    // MARK: release budget

    /// RESULTS.md "Frame budget": with a partial holding the (fake) ANE at release, release→sttDone
    /// stays near the no-partials baseline because the partial is cancelled first. The regression
    /// (partial not cancelled) holds the ANE ~300 ms longer, several times the ~40 ms baseline, so
    /// the always-on bound is relative (≤ 1.5× baseline): it scales with a slow shared runner, where
    /// an absolute 10 ms failed on scheduling noise (0.092 s vs 0.073 s). The 10 ms budget itself is
    /// still checked off CI.
    func test_releaseWithPartialInFlight_staysWithinBudget() async throws {
        func releaseToSTT(partials: Bool) async throws -> Duration {
            let events = EventLog<String>()
            let audio = FixtureAudioCapture(events: events)
            let engine = FakeANETranscriber(events: events)
            let timings = TimingLog()
            let h = makeHarness(audio: audio, now: { .now }, onTiming: { timings.append($0) }, livePartials: partials)
            let session = DictationSession(
                hotkey: h.hotkey, audio: audio, transcriber: engine, cleanup: RawBackend(),
                injectors: InjectorChain(ax: h.ax, paste: h.paste, unicode: h.unicode), contextProvider: h.context,
                dictionaryStore: InMemoryDictionaryStore(), settingsStore: h.settings, clipboard: h.clipboard, undo: h.undo,
                onTiming: { timings.append($0) }, livePartials: partials
            )
            await session.start()
            await h.hotkey.press()
            if partials {
                await waitFor("partials.start", in: events)
                audio.pushChunk()
                await waitFor("partials.inFlight", in: events)
            } else {
                try? await Task.sleep(for: .milliseconds(20))
            }
            await h.hotkey.release()
            await session.drain(handled: 2)
            return try XCTUnwrap(timings.snapshot().first?.stt, "no timing reported")
        }
        _ = try await releaseToSTT(partials: false) // warm-up: first-run costs land in neither series
        _ = try await releaseToSTT(partials: true)
        var baseline: [Duration] = [], withPartial: [Duration] = []
        for _ in 0..<7 { // interleaved, so a burst of load hits both series
            baseline.append(try await releaseToSTT(partials: false))
            withPartial.append(try await releaseToSTT(partials: true))
        }
        let base = baseline.sorted()[3], partial = withPartial.sorted()[3]
        let detail = "median release→sttDone \(partial) vs baseline \(base)"
        XCTAssertLessThanOrEqual(partial, base * 1.5, detail)
        if ProcessInfo.processInfo.environment["CI"] == nil {
            XCTAssertLessThan(partial - base, .milliseconds(10), detail)
        }
    }
}

/// Resolves to whichever engine is selected at press, like the app's SwitchingTranscriber.
final class PinnedSwitch: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any Transcribing
    init(_ engine: any Transcribing) { current = engine }
    func select(_ engine: any Transcribing) { lock.withLock { current = engine } }
    func engineForUtterance() -> any Transcribing { lock.withLock { current } }
    func transcribe(_ buffer: AudioBuffer) -> AsyncThrowingStream<TranscriptChunk, Error> { engineForUtterance().transcribe(buffer) }
    func partials(_ audio: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<PartialTranscript, Error> { engineForUtterance().partials(audio) }
}

/// One serial "ANE" shared by partials and the final, like FluidAudio's AsrManager actor. A
/// partial holds it for 300 ms but checks cancellation between 2 ms stages, as FluidAudio does
/// between pipeline stages (RESULTS.md "Frame budget").
final class FakeANETranscriber: Transcribing {
    let ane = AsyncLock()
    let events: EventLog<String>
    init(events: EventLog<String>) { self.events = events }

    func partials(_ audio: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<PartialTranscript, Error> {
        let (ane, events) = (ane, events)
        return AsyncThrowingStream { continuation in
            events.append("partials.start")
            let task = Task {
                for await _ in audio {
                    await ane.acquire()
                    events.append("partials.inFlight")
                    for _ in 0..<150 where !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
                    await ane.release()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func transcribe(_ buffer: AudioBuffer) -> AsyncThrowingStream<TranscriptChunk, Error> {
        let ane = ane
        return AsyncThrowingStream { continuation in
            Task {
                await ane.acquire()
                try? await Task.sleep(for: .milliseconds(40))
                await ane.release()
                continuation.yield(TranscriptChunk(text: "hello world"))
                continuation.finish()
            }
        }
    }
}

actor RecordingCleanup: CleanupBackend {
    private(set) var requests: [CleanupRequest] = []
    private func record(_ r: CleanupRequest) { requests.append(r) }
    nonisolated func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                continuation.yield(request.rawTranscript)
                continuation.finish()
            }
        }
    }
}

final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PartialTranscript?] = []
    func append(_ p: PartialTranscript?) { lock.withLock { values.append(p) } }
    func snapshot() -> [PartialTranscript?] { lock.withLock { values } }
}

final class RawLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ s: String) { lock.withLock { values.append(s) } }
    func snapshot() -> [String] { lock.withLock { values } }
}
