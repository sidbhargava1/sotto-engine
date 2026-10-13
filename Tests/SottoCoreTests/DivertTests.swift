// A dictation press turned into a diverted utterance mid-hold (HotkeyEvent.divert). Fakes only.
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

final class DivertTests: SessionTestCase {
    private func collectPartials(_ h: Harness) async -> PartialLog {
        let log = PartialLog()
        let stream = await h.session.partialUpdates()
        Task { for await p in stream { log.append(p) } }
        return log
    }

    private func assertNothingDelivered(_ h: Harness, history: RecordingHistory, backend: FixtureBackend, file: StaticString = #filePath, line: UInt = #line) async {
        let injected = await h.ax.injectedText()
        let pasted = await h.paste.injectedText()
        let typed = await h.unicode.injectedText()
        let copied = await h.clipboard.copied
        let cleanupCalls = await backend.calls
        XCTAssertEqual([injected, pasted, typed], ["", "", ""], file: file, line: line)
        XCTAssertTrue(copied.isEmpty, file: file, line: line)
        XCTAssertEqual(cleanupCalls, 0, file: file, line: line)
        XCTAssertTrue(history.records.isEmpty && history.offers.isEmpty, file: file, line: line)
    }

    func test_divertMidPress_deliversFullTranscriptToSinkOnly() async {
        let sink = RecordingSink()
        let history = RecordingHistory()
        let backend = FixtureBackend(steps: [.init("MODEL")])
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber([.text("  before and after  ")], partials: .perChunk([PartialTranscript(stable: "before", volatile: "", audioSeconds: 1)]), events: events),
                            backend: backend, audio: audio, history: history, divertSink: sink)
        await h.settings.update { $0.cleanupEngine = .local }
        let states = await collectStates(h)
        let partials = await collectPartials(h)
        let raw = RawLog()
        let rawStream = await h.session.rawTranscriptUpdates()
        Task { for await t in rawStream { raw.append(t) } }
        await h.session.start()
        await h.hotkey.press()
        await waitUntil("capture start") { await audio.calls.contains("start") }
        audio.pushChunk()
        await h.hotkey.divert()
        await h.hotkey.release()
        await settle(h)

        XCTAssertEqual(sink.received, ["before and after"])
        let calls = await audio.calls
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1, "divert must not restart capture")
        XCTAssertEqual(calls.filter { $0 == "stop" }.count, 1)
        await assertNothingDelivered(h, history: history, backend: backend)
        XCTAssertTrue(raw.snapshot().isEmpty, "no raw-transcript snapshot for a diverted utterance")
        let settled = await states.settled()
        XCTAssertEqual(settled, [.recording, .transcribing, .idle])
        try? await Task.sleep(for: .milliseconds(20))
        let shown = partials.snapshot()
        XCTAssertTrue(shown.last == .some(nil), "displayed partials end with nil: \(shown)")
    }

    func test_divertCancelsPartialsAtDivert() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber(partials: .hang, events: events), audio: audio, divertSink: RecordingSink())
        let partials = await collectPartials(h)
        await h.session.start()
        await h.hotkey.press()
        await waitUntil("partials start") { events.snapshot().contains("partials.start") }
        await h.hotkey.divert()
        await waitUntil("partials cancelled") { events.snapshot().contains("partials.cancelled") }
        XCTAssertEqual(partials.snapshot(), [nil])
        await h.hotkey.release()
        await settle(h)
    }

    func test_divertedCap_firesAtDivertedDuration_notDictationCap() async {
        let sink = RecordingSink()
        let h = makeHarness(maxRecordingDuration: .milliseconds(150), divertSink: sink, maxDivertedDuration: .seconds(2))
        await h.session.start()
        await h.hotkey.press()
        await waitUntil("capture start") { await h.audio.calls.contains("start") }
        await h.hotkey.divert()
        try? await Task.sleep(for: .milliseconds(450)) // well past the dictation cap
        let early = await h.audio.calls
        XCTAssertFalse(early.contains("stop"), "the dictation cap must not stop a diverted recording")
        await h.hotkey.release()
        await settle(h)
        XCTAssertEqual(sink.received, ["hello world"])
    }

    func test_divertedCap_stopsAtMaxDivertedDuration() async {
        let sink = RecordingSink()
        let h = makeHarness(maxRecordingDuration: .seconds(60), divertSink: sink, maxDivertedDuration: .milliseconds(40))
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.divert()
        await waitUntil("the diverted cap's stop") { await h.audio.calls.contains("stop") }
        await h.hotkey.release() // late physical release is a no-op
        await settle(h)
        XCTAssertEqual(sink.received, ["hello world"])
    }

    func test_divertWithoutSink_isIgnored() async {
        let h = makeHarness(maxRecordingDuration: .milliseconds(60))
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.divert()
        await h.hotkey.release()
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
    }

    func test_divertAfterRelease_isIgnored() async {
        let sink = RecordingSink()
        let h = makeHarness(divertSink: sink)
        await runUtterance(h)
        await h.hotkey.divert()
        await settle(h)
        XCTAssertTrue(sink.received.isEmpty)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
        // and it must not poison the next press
        await h.hotkey.press()
        await h.hotkey.release()
        await settle(h)
        XCTAssertTrue(sink.received.isEmpty)
    }

    func test_repeatedDivert_isIdempotent() async {
        let sink = RecordingSink()
        let h = makeHarness(maxRecordingDuration: .seconds(60), divertSink: sink, maxDivertedDuration: .seconds(60))
        await h.session.start()
        await h.hotkey.press()
        for _ in 0..<3 { await h.hotkey.divert() }
        await h.hotkey.release()
        await settle(h)
        XCTAssertEqual(sink.received, ["hello world"])
    }

    func test_divertOnCommandPress_isIgnored() async {
        let sink = RecordingSink()
        let h = makeHarness(commandInputs: CommandInputs(commandsEnabled: true, commandKeyEnabled: true), divertSink: sink)
        await h.session.start()
        await h.hotkey.pressCommand()
        await h.hotkey.divert()
        await h.hotkey.releaseCommand()
        await settle(h)
        XCTAssertTrue(sink.received.isEmpty, "a command press is never diverted")
        let calls = await h.audio.calls
        XCTAssertEqual(calls.filter { $0 == "stop" }.count, 1)
    }

    func test_dictationWithoutDivert_unchangedWhenSinkSupplied() async {
        let sink = RecordingSink()
        let h = makeHarness(divertSink: sink)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
        XCTAssertTrue(sink.received.isEmpty)
    }

    func test_sttFailureOnDivertedUtterance_emitsErrorAndSkipsSink() async {
        let sink = RecordingSink()
        let silent = AudioBuffer(samples: [0.1])
        let h = makeHarness(transcriber: FixtureTranscriber([.fail(FakeError(label: "stt-down"))]), audio: FixtureAudioCapture(buffers: [silent]), divertSink: sink)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.divert()
        await h.hotkey.release()
        await settle(h)
        XCTAssertTrue(sink.received.isEmpty)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.recording, .transcribing, .error(.sttFailed), .idle])
    }

    func test_emptyTranscriptOnDivertedUtterance_isNoSpeechAndSkipsSink() async {
        let sink = RecordingSink()
        let h = makeHarness(transcriber: FixtureTranscriber([.text("   ")]), divertSink: sink)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.divert()
        await h.hotkey.release()
        await settle(h)
        XCTAssertTrue(sink.received.isEmpty)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.recording, .transcribing, .error(.sttFailed), .idle])
    }

    func test_divertedRecordingCountsAsRecordingForIdleSleep() async {
        let h = makeHarness(idleSleepGrace: .milliseconds(10), divertSink: RecordingSink())
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.divert()
        await h.session.scheduleIdleSleep()
        try? await Task.sleep(for: .milliseconds(100))
        let calls = await h.audio.calls
        XCTAssertFalse(calls.contains("sleep"))
        await h.hotkey.release()
        await settle(h)
    }
}
