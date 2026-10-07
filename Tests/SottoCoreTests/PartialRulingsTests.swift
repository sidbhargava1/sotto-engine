// QA rulings for live partials (Phase 6 step 1): frozen words, empty/filler hypotheses, gate
// boundaries, ceiling, and the display-only guarantee at the session seam. Fakes only.
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

final class PartialStabilizerRulingsTests: XCTestCase {
    private func shows(_ s: inout PartialStabilizer, _ text: String, _ t: Double, onset: Double? = 0) -> PartialTranscript? {
        if case .show(let p) = s.ingest(text, audioSeconds: t, onset: onset) { return p }
        return nil
    }

    // MARK: frozen words

    func test_shorterHypothesisNeverShrinksOrCrashesStable() {
        var s = PartialStabilizer()
        _ = s.ingest("one two three four", audioSeconds: 1, onset: 0)
        _ = s.ingest("one two three four", audioSeconds: 2, onset: 0)
        let first = shows(&s, "one two three four", 3)
        XCTAssertEqual(first?.stable, "one two three four")
        for (i, text) in ["one", "one two", "uno", "x", "one two three four five"].enumerated() {
            let out = s.ingest(text, audioSeconds: 4 + Double(i), onset: 0)
            if case .show(let p) = out { XCTAssertTrue(p.stable.hasPrefix("one two three four"), "\(text) -> \(p)") }
        }
    }

    func test_confirmedWordsFrozenWhenLaterHypothesesDisagree() {
        var s = PartialStabilizer()
        for t in 1...3 { _ = s.ingest("send it now", audioSeconds: Double(t), onset: 0) }
        let p = shows(&s, "end of the day", 4)
        XCTAssertEqual(p?.stable, "send it now", "a confirmed word is never retracted; the final corrects it")
    }

    // MARK: empty / whitespace / punctuation

    func test_emptyWhitespacePunctuationAreIgnoredAndDontBreakTheRun() {
        for noise in ["", "   ", "\n\t", "...", "—", "?!", "…", " . , "] {
            var s = PartialStabilizer()
            XCTAssertEqual(s.ingest(noise, audioSeconds: 0.5, onset: 0), .hold, "\(noise.debugDescription) emits nothing")
            _ = s.ingest("hello there friend", audioSeconds: 1, onset: 0)
            _ = s.ingest("hello there friend", audioSeconds: 2, onset: 0)  // LA-2 shows "hello there"
            XCTAssertEqual(s.ingest(noise, audioSeconds: 2.5, onset: 0), .hold, noise.debugDescription)
            XCTAssertEqual(shows(&s, "hello there friend", 3), PartialTranscript(stable: "hello there friend", volatile: "", audioSeconds: 3),
                           "\(noise.debugDescription) broke the agreement run")
        }
    }

    func test_agreementIsCaseAndPunctuationInsensitive() {
        var s = PartialStabilizer()
        _ = s.ingest("Hello, World.", audioSeconds: 1, onset: 0)
        _ = s.ingest("hello world", audioSeconds: 2, onset: 0)
        let p = shows(&s, "HELLO WORLD! and", 3)
        XCTAssertEqual(p?.stable, "HELLO WORLD!")
        XCTAssertEqual(p?.volatile, "and")
    }

    // MARK: filler guard

    func test_fillerOnlyHypothesesNeverShow_evenPersistingThreeTicks() {
        for filler in ["okay okay", "Mm-hmm.", "mm hmm", "Yeah!", "um…", "Okay okay okay.", "Uh, um"] {
            var s = PartialStabilizer()
            for t in 1...5 { XCTAssertEqual(s.ingest(filler, audioSeconds: Double(t), onset: 0), .hold, filler) }
        }
    }

    func test_fillerTickDoesntBreakARun() {
        var s = PartialStabilizer()
        _ = s.ingest("send it now", audioSeconds: 1, onset: 0)
        _ = s.ingest("send it now", audioSeconds: 2, onset: 0)
        XCTAssertEqual(s.ingest("Mm-hmm.", audioSeconds: 2.5, onset: 0), .hold)
        XCTAssertEqual(shows(&s, "send it now", 3)?.stable, "send it now")
    }

    func test_anyRealWordKeepsTheHypothesis() {
        for text in ["okay send", "Yeah, right", "um hello", "mm-hmm sure", "ok."] where text != "ok." {
            var s = PartialStabilizer()
            let shown = (1...3).compactMap { shows(&s, text, Double($0)) }
            XCTAssertFalse(shown.isEmpty, text)
        }
    }

    // MARK: onset gate boundary

    func test_gateBoundary_079Holds_080Shows() {
        var s = PartialStabilizer()
        _ = s.ingest("hello there", audioSeconds: 0.3, onset: 0)
        _ = s.ingest("hello there", audioSeconds: 0.5, onset: 0)
        XCTAssertEqual(s.ingest("hello there", audioSeconds: 0.79, onset: 0), .hold)
        XCTAssertEqual(shows(&s, "hello there", 0.80), PartialTranscript(stable: "hello there", volatile: "", audioSeconds: 0.80))
    }

    func test_gateBoundaryWithNonZeroOnset() {
        var s = PartialStabilizer()
        _ = s.ingest("hello there", audioSeconds: 0.9, onset: 0.5)
        _ = s.ingest("hello there", audioSeconds: 1.1, onset: 0.5)
        XCTAssertEqual(s.ingest("hello there", audioSeconds: 1.29, onset: 0.5), .hold)
        XCTAssertNotNil(shows(&s, "hello there", 1.30, onset: 0.5))
    }

    func test_noOnsetEver_nothingIsEmitted() {
        var s = PartialStabilizer()
        for t in 1...12 { XCTAssertEqual(s.ingest("words keep coming \(t % 2)", audioSeconds: Double(t), onset: nil), .hold) }
    }

    // MARK: ceiling

    func test_ceiling_stopsAtExactly14s_notBefore() {
        var s = PartialStabilizer()
        XCTAssertNotEqual(s.ingest("so this is long", audioSeconds: 13.99, onset: 0), .stop)
        XCTAssertEqual(s.ingest("so this is long", audioSeconds: 14.0, onset: 0), .stop)
        XCTAssertEqual(s.ingest("so this is long", audioSeconds: 15, onset: 0), .stop)
    }

    func test_nothingDuplicatedOrDroppedBeforeTheCeiling() {
        let sentence = (1...60).map { "w\($0)" }
        var s = PartialStabilizer()
        var last: PartialTranscript?
        var t = 0.4
        var spoken = 3
        while t < PartialStabilizer.maxAudioSeconds {
            let text = sentence.prefix(spoken).joined(separator: " ")
            if case .show(let p) = s.ingest(text, audioSeconds: t, onset: 0) {
                let words = (p.stable + " " + p.volatile).split(separator: " ").map(String.init)
                XCTAssertEqual(words, Array(sentence.prefix(words.count)), "duplicated/dropped at \(t)")
                if let last { XCTAssertTrue(p.stable.hasPrefix(last.stable)) }
                last = p
            }
            t = (t * 10 + 4).rounded() / 10
            spoken += 1
        }
        XCTAssertNotNil(last)
        XCTAssertEqual(s.ingest("w1", audioSeconds: 14.0, onset: 0), .stop)
    }
}

final class OnsetDetectorRulingsTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * Float(sin(2 * .pi * 220 * Double($0) / 16_000)) }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.001, count: Int(seconds * 16_000)) }

    func test_sustainBoundary_40msNo_60msYes() throws {
        var short = OnsetDetector()
        XCTAssertNil(short.feed(silence(0.1) + tone(0.04) + silence(0.5)))
        var long = OnsetDetector()
        let onset = try XCTUnwrap(long.feed(silence(0.1) + tone(0.06) + silence(0.1)))
        XCTAssertEqual(onset, 0.1, accuracy: 0.001)
    }

    func test_interruptedBurstsNeverAccumulate() {
        var d = OnsetDetector()
        var audio: [Float] = []
        for _ in 0..<20 { audio += tone(0.04) + silence(0.02) }
        XCTAssertNil(d.feed(audio))
    }

    func test_noOnset_stabilizerNeverEmits() {
        var d = OnsetDetector(), s = PartialStabilizer()
        for t in 1...10 {
            d.feed(silence(0.4))
            XCTAssertEqual(s.ingest("Okay so", audioSeconds: Double(t) * 0.4, onset: d.onset), .hold)
        }
    }
}

final class PartialsRulingsSessionTests: SessionTestCase {
    private let sentinel = "SENTINELZQX7"
    private func snap(_ text: String, _ seconds: Double = 1) -> PartialTranscript {
        PartialTranscript(stable: text, volatile: "", audioSeconds: seconds)
    }
    private func collect(_ session: DictationSession) async -> PartialLog {
        let log = PartialLog()
        let stream = await session.partialUpdates()
        Task { for await p in stream { log.append(p) } }
        return log
    }
    private func waitFor(_ event: String, in log: EventLog<String>) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !log.snapshot().contains(event), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(log.snapshot().contains(event), "never saw \(event)")
    }
    private func waitForCount(_ log: PartialLog, _ n: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while log.snapshot().count < n, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    // MARK: stream throws mid-hold

    func test_partialsThrowMidHold_utteranceStillCompletes() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let p1 = snap("so I think")
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world")], partials: .yieldThenFail([p1], FakeError(label: "ane")), events: events), audio: audio)
        let partials = await collect(h.session)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        audio.pushChunk() // throws here
        await waitForCount(partials, 2)
        XCTAssertEqual(partials.snapshot(), [p1, nil])
        await h.hotkey.release()
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
        let all = await states.settled()
        XCTAssertFalse(all.contains { if case .error = $0 { true } else { false } }, "\(all)")
        XCTAssertEqual(all.last, .idle)
    }

    // MARK: display-only

    func test_sentinelNeverReachesCleanupInjectionClipboardOrTiming() async {
        for hasTarget in [true, false] {
            let events = EventLog<String>()
            let audio = FixtureAudioCapture(events: events)
            let backend = RecordingCleanup()
            let timings = TimingLog()
            let h = makeHarness(
                transcriber: FixtureTranscriber([.text("hello world")], partials: .perChunk([snap(sentinel), PartialTranscript(stable: "x", volatile: sentinel, audioSeconds: 2)]), events: events),
                backend: backend, audio: audio, context: FakeContextProvider(makeTestContext(hasTarget: hasTarget)), onTiming: { timings.append($0) }
            )
            let partials = await collect(h.session)
            await h.session.start()
            await h.hotkey.press()
            await waitFor("partials.start", in: events)
            audio.pushChunk()
            audio.pushChunk()
            await waitForCount(partials, 2)
            await h.hotkey.release()
            await settle(h)
            XCTAssertTrue(partials.snapshot().contains { $0?.stable == sentinel }, "sentinel was shown on the bubble channel")

            let requests = await backend.requests
            XCTAssertFalse(requests.isEmpty)
            XCTAssertFalse(requests.contains { String(describing: $0).contains(sentinel) }, "CleanupRequest")
            let texts = [await h.ax.injectedText(), await h.paste.injectedText(), await h.unicode.injectedText()]
            XCTAssertFalse(texts.contains { $0.contains(sentinel) }, "injected")
            let copied = await h.clipboard.copied
            XCTAssertFalse(copied.contains { $0.contains(sentinel) }, "clipboard")
            XCTAssertFalse(String(describing: timings.snapshot()).contains(sentinel), "onTiming")
            XCTAssertEqual(requests.map(\.rawTranscript), ["hello world"])
        }
    }

    func test_partialScratchThatOverPlainFinal_noUndo() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world")], partials: .perChunk([snap("scratch that")]), events: events), audio: audio)
        let partials = await collect(h.session)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await settle(h)
        let undos = await h.undo.callCount()
        let injected = await h.ax.injectedText()
        XCTAssertEqual(undos, 0)
        XCTAssertEqual(injected, "hello world")
    }

    func test_finalScratchThatOverPlainPartial_firesUndo() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world"), .text("scratch that")], partials: .perChunk([snap("hello world")]), events: events), audio: audio)
        let partials = await collect(h.session)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await settle(h)
        let undos = await h.undo.callCount()
        XCTAssertEqual(undos, 1, "the final decides commands, whatever the bubble showed")
    }

    // MARK: re-press / clearing

    func test_repress_noStalePartialLeaksIntoNextUtterance() async {
        let a = FixtureTranscriber([.text("from a")], partials: .perChunk([snap("STALE-A")]))
        let b = FixtureTranscriber([.text("from b")], partials: .perChunk([snap("fresh-b")]))
        let switching = PinnedSwitch(a)
        let audio = FixtureAudioCapture(events: EventLog<String>())
        let h = makeHarness(transcriber: FixtureTranscriber(), audio: audio)
        let session = DictationSession(
            hotkey: h.hotkey, audio: audio, transcriber: switching, cleanup: RawBackend(),
            injectors: InjectorChain(ax: h.ax, paste: h.paste, unicode: h.unicode), contextProvider: h.context,
            dictionaryStore: InMemoryDictionaryStore(), settingsStore: h.settings, clipboard: h.clipboard, undo: h.undo
        )
        let partials = await collect(session)
        await session.start()
        await h.hotkey.press()
        try? await Task.sleep(for: .milliseconds(20))
        audio.pushChunk()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await session.drain(handled: 2)
        switching.select(b)
        await h.hotkey.press()
        try? await Task.sleep(for: .milliseconds(20))
        audio.pushChunk() // chunk from utterance 2 only
        await waitForCount(partials, 3)
        audio.pushChunk() // beyond b's script: nothing more may appear
        try? await Task.sleep(for: .milliseconds(20))
        await h.hotkey.release()
        await session.drain(handled: 4)
        try? await Task.sleep(for: .milliseconds(20))
        let seen = partials.snapshot()
        XCTAssertEqual(seen.compactMap { $0?.stable }, ["STALE-A", "fresh-b"])
        let afterSecondPress = Array(seen.drop { $0 != nil }.drop { $0 == nil })
        XCTAssertFalse(afterSecondPress.contains { $0?.stable == "STALE-A" })
        XCTAssertNil(seen.last ?? nil)
    }

    func test_micDenied_neverShowsPartials_andStreamEndsCleared() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        await audio.setStartError(FakeError(label: "mic-denied"))
        let h = makeHarness(transcriber: FixtureTranscriber(partials: .perChunk([snap("junk")]), events: events), audio: audio)
        let partials = await collect(h.session)
        let states = await collectStates(h)
        await runUtterance(h)
        audio.pushChunk()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(partials.snapshot().contains { $0 != nil })
        XCTAssertFalse(events.snapshot().contains("partials.start"), "no recording, no partials task")
        let settled = await states.settled()
        XCTAssertEqual(settled, [.error(.micDenied), .idle])
    }

    func test_micDeniedOnRepress_clearsPriorUtterancesPartial() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hi there")], partials: .perChunk([snap("hi")]), events: events), audio: audio)
        let partials = await collect(h.session)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await settle(h)
        await audio.setStartError(FakeError(label: "mic-denied"))
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(partials.snapshot(), [snap("hi"), nil])
    }

    func test_emptyBufferError_endsWithClearedPartial() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(buffers: [AudioBuffer(samples: [])], events: events)
        let h = makeHarness(transcriber: FixtureTranscriber(partials: .perChunk([snap("ghost")]), events: events), audio: audio)
        let partials = await collect(h.session)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await settle(h)
        let all = await states.settled()
        XCTAssertTrue(all.contains(.error(.sttFailed)))
        XCTAssertNil(partials.snapshot().last ?? snap("not-nil"))
    }

    func test_maxDurationStop_clearsPartialAndLateChunksDontLeak() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world")], partials: .perChunk([snap("one"), snap("two"), snap("three")]), events: events), audio: audio, maxRecordingDuration: .milliseconds(150))
        let partials = await collect(h.session)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        await waitFor("transcribe", in: events)
        audio.pushChunk() // after the cap: capture is stopped
        await h.hotkey.release()
        await settle(h)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(partials.snapshot(), [snap("one"), nil])
    }

    func test_idleAfterUtterance_streamEndsCleared() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world")], partials: .perChunk([snap("hello")]), events: events), audio: audio)
        let partials = await collect(h.session)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press()
        await waitFor("partials.start", in: events)
        audio.pushChunk()
        await waitForCount(partials, 1)
        await h.hotkey.release()
        await settle(h)
        let all = await states.settled()
        XCTAssertEqual(all.last, .idle)
        XCTAssertEqual(partials.snapshot().last, .some(nil))
    }
}
