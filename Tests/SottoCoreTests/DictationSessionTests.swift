// Scenario ids reference docs/phase1-test-scenarios.md. Every `DictationSession` end-to-end test
// (PLAN §7) runs with fakes only — zero permissions, zero microphone, zero network.
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

final class DictationSessionTests: SessionTestCase {
    // MARK: DS-01 — warm-up delay before STT is ready doesn't crash or hang

    func test_DS01_transcriberWarmupDelayDoesNotCrash() async {
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello world")], warmup: .milliseconds(300)))
        let states = await collectStates(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world", "waits for STT rather than transcribing nothing")
        let settled = await states.settled()
        XCTAssertFalse(settled.contains { if case .error = $0 { true } else { false } }, "\(settled)")
    }

    // MARK: DS-02 — recording B may start while A is still injecting; never interleaved

    func test_DS02_secondUtteranceNeverInterleavesWithFirstsInjection() async {
        // Driven by gates, not sleeps: A is provably mid-injection (one chunk typed, the rest held)
        // when B is recorded and transcribed.
        let backend = GatedBackend(tokens: ["A1 ", "A2 ", "A3"])
        let audio = FixtureAudioCapture(buffers: [AudioBuffer(samples: [0.1]), AudioBuffer(samples: [0.2])])
        let transcriber = FixtureTranscriber([.text("first"), .text("second")])
        let h = makeHarness(transcriber: transcriber, backend: backend, audio: audio)

        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.release()
        await backend.open() // A's first token only
        await waitUntil("A's first chunk") { await h.ax.injectedText() == "A1 " }

        await h.hotkey.press() // B's recording starts while A is still injecting (DS-02)
        await h.hotkey.release()
        await waitUntil("B's transcription") { transcriber.events.snapshot().filter { $0 == "transcribe" }.count == 2 }
        // Room for a broken lock to let B through; the assertions hold however long this takes.
        try? await Task.sleep(for: .milliseconds(20))
        let cleanups = await backend.calls
        XCTAssertEqual(cleanups, 1, "B's cleanup waits for A's delivery")
        let typedSoFar = await h.ax.injectedText()
        XCTAssertEqual(typedSoFar, "A1 ", "nothing of B's lands while A holds the target")

        await backend.openAll()
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "A1 A2 A3A1 A2 A3", "A's chunks then B's, never interleaved: \(injected)")
    }

    // MARK: DS-03 — empty/silence transcript -> error, nothing injected

    func test_DS03_emptyTranscriptGoesToErrorNotInjection() async {
        let transcriber = FixtureTranscriber([.text("")])
        let h = makeHarness(transcriber: transcriber)
        let states = await collectStates(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertTrue(injected.isEmpty)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.recording, .transcribing, .error(.sttFailed), .idle])
    }

    // MARK: DS-04b — STT weights not downloaded: its own reason, not "Didn't catch that"

    func test_DS04b_missingModelSaysSoAndTypesNothing() async {
        let h = makeHarness(transcriber: FixtureTranscriber([.fail(ModelNotDownloaded(ModelID("parakeet")))]))
        let states = await collectStates(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertTrue(injected.isEmpty)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.recording, .transcribing, .error(.modelMissing), .idle])
    }

    // MARK: DS-03b — the input delivered only digital silence: say which device, still nothing typed

    func test_DS03b_silentInputNamesTheDevice() async {
        let silent = AudioBuffer(samples: [0, 0, 0], silentInput: .init(device: "Sidpod Pro"))
        let h = makeHarness(transcriber: FixtureTranscriber([.text("")]), audio: FixtureAudioCapture(buffers: [silent]))
        let states = await collectStates(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertTrue(injected.isEmpty)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.recording, .transcribing, .error(.silentInput(device: "Sidpod Pro")), .idle])
    }

    func test_DS03b_silentInputThatStillTranscribes_isTypedNormally() async {
        // Display only: if STT found words anyway, the flag never stops delivery.
        let silent = AudioBuffer(samples: [0, 0, 0], silentInput: .init(device: nil))
        let h = makeHarness(audio: FixtureAudioCapture(buffers: [silent]))
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertFalse(injected.isEmpty)
    }

    func test_DS03b_silentInputSttFailure_unknownDevice() async {
        let silent = AudioBuffer(samples: [0, 0, 0], silentInput: .init(device: nil))
        let h = makeHarness(transcriber: FixtureTranscriber([.fail(FakeError(label: "stt-down"))]), audio: FixtureAudioCapture(buffers: [silent]))
        let states = await collectStates(h)
        await runUtterance(h)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.recording, .transcribing, .error(.silentInput(device: nil)), .idle])
    }

    // MARK: DS-04 — STT throws -> error, nothing injected

    func test_DS04_sttThrowsGoesToErrorNotInjection() async {
        let transcriber = FixtureTranscriber([.fail(FakeError(label: "stt-down"))])
        let h = makeHarness(transcriber: transcriber)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertTrue(injected.isEmpty)
    }

    // MARK: DS-05 — unverified AX result does not fall back to paste

    func test_DS05_unverifiedAXDoesNotFallBackToPaste() async {
        let h = makeHarness(axOutcomes: [.unverified])
        await runUtterance(h)
        let axCalls = await h.ax.calls.count
        let pasteCalls = await h.paste.calls.count
        XCTAssertGreaterThanOrEqual(axCalls, 1)
        XCTAssertEqual(pasteCalls, 0, "unverified must not trigger a paste fallback (double-insert risk)")
    }

    // MARK: DS-05b — every injector fails -> clipboard, never dropped

    func test_DS05b_allInjectorsFailingCopiesToClipboard() async {
        let h = makeHarness(axOutcomes: [.failed], pasteOutcomes: [.failed], unicodeOutcomes: [.failed])
        let states = await collectStates(h)
        await runUtterance(h)
        let copied = await h.clipboard.copied
        XCTAssertEqual(copied, ["hello world"])
        let settled = await states.settled()
        XCTAssertTrue(settled.contains(.degraded(.copiedNoTarget)), "AX is granted here, so the reason is no target: \(settled)")
    }

    func test_DS05c_injectorsFailingMidStreamCopyTheRest() async {
        let backend = FixtureBackend(steps: [.init("one "), .init("two ", after: .milliseconds(40)), .init("three", after: .milliseconds(40))])
        let h = makeHarness(backend: backend, axOutcomes: [.success, .failed], pasteOutcomes: [.failed], unicodeOutcomes: [.failed])
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        let copied = await h.clipboard.copied
        XCTAssertTrue(injected.hasPrefix("one "), injected)
        XCTAssertEqual(copied, ["two three"], "the failed chunk and everything after it")
        let unicodeCalls = await h.unicode.callCount()
        XCTAssertEqual(unicodeCalls, 1, "no further injection attempts once the chain has failed")
    }

    // MARK: DS-06 — no focused editable target -> clipboard, degraded

    func test_DS06_noEditableTargetCopiesToClipboard() async {
        let context = FakeContextProvider(makeTestContext(bundleID: nil, hasTarget: false, axGranted: true))
        let h = makeHarness(context: context)
        let states = await collectStates(h)
        await runUtterance(h)
        let copied = await h.clipboard.copied
        let axCalls = await h.ax.calls.count
        XCTAssertEqual(copied, ["hello world"])
        XCTAssertEqual(axCalls, 0)
        let settled = await states.settled()
        XCTAssertEqual(settled.suffix(2), [.degraded(.copiedNoTarget), .idle])
    }

    // MARK: DS-07 — terminal-class target strips newlines/tabs, never sends Return

    func test_DS07_terminalClassStripsNewlinesAndTabs() async {
        let transcriber = FixtureTranscriber([.text("line one\nline two\ttabbed")])
        let context = FakeContextProvider(makeTestContext(isTerminalClass: true))
        let h = makeHarness(transcriber: transcriber, context: context)
        await runUtterance(h)
        let injected = await h.unicode.injectedText()
        XCTAssertFalse(injected.contains("\n"))
        XCTAssertFalse(injected.contains("\t"))
        XCTAssertEqual(injected, "line one line two tabbed")
    }

    // MARK: DS-08 — discrete event only, independent of physical modifier state

    func test_DS08_releaseEventAloneDrivesTransition() async {
        let h = makeHarness()
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.release() // the only signal DictationSession looks at
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
    }

    // MARK: DS-09 — rapid press/release pairs never race the one AudioCapturing instance

    func test_DS09_rapidPressReleasePairsDoNotRaceCapture() async {
        let transcriber = FixtureTranscriber([.text("one"), .text("two")])
        let audio = FixtureAudioCapture(buffers: [AudioBuffer(samples: [0.1]), AudioBuffer(samples: [0.2])])
        let h = makeHarness(transcriber: transcriber, audio: audio)
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.release()
        try? await Task.sleep(for: .milliseconds(10))
        await h.hotkey.press()
        await h.hotkey.release()
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertTrue(injected.contains("one"))
        XCTAssertTrue(injected.contains("two"))
    }

    // MARK: DS-10 — a settings rebind mid-recording doesn't corrupt the in-flight utterance

    func test_DS10_settingsChangeMidRecordingDoesNotCorruptSession() async {
        let h = makeHarness()
        await h.session.start()
        await h.hotkey.press()
        await h.settings.update { $0.injectionOverrides["com.other.app"] = .paste } // unrelated rebind-style change
        await h.hotkey.release()
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world", "mid-hold settings changes must not affect the active utterance")
    }

    // MARK: DS-10b/c — Pause ends a held recording; the next press unpauses

    func test_DS10b_pauseMidHoldStillEndsTheRecording() async {
        let h = makeHarness()
        await h.session.start()
        await h.hotkey.press()
        await settle(h)
        await h.settings.update { $0.paused = true }
        await h.hotkey.release()
        await settle(h)
        await h.settings.update { $0.paused = false }
        await h.hotkey.press() // would be swallowed by a wedged isRecording
        await h.hotkey.release()
        await settle(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello worldhello world")
    }

    func test_DS10c_pressWhilePausedUnpausesAndRecords() async {
        let h = makeHarness()
        await h.settings.update { $0.paused = true }
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
        let paused = await h.settings.load().paused
        XCTAssertFalse(paused)
    }

    // MARK: DS-11 — filler-only transcript passes through without crashing

    func test_DS11_fillerOnlyTranscriptPassesThroughRaw() async {
        let transcriber = FixtureTranscriber([.text("um uh so")])
        let h = makeHarness(transcriber: transcriber)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "um uh so")
    }

    // MARK: DS-12 — max-duration cap force-stops; a later physical release is a no-op

    func test_DS12_maxDurationCapForceStopsRecording() async {
        let h = makeHarness(coalescerConfig: CoalescerConfig(flushInterval: .milliseconds(10), firstTokenTimeout: .milliseconds(40), stallTimeout: .milliseconds(40)))
        let cappedSession = DictationSession(
            hotkey: h.hotkey, audio: h.audio, transcriber: h.transcriber, cleanup: RawBackend(),
            injectors: InjectorChain(ax: h.ax, paste: h.paste, unicode: h.unicode),
            contextProvider: h.context, dictionaryStore: InMemoryDictionaryStore(), settingsStore: h.settings,
            clipboard: h.clipboard, undo: h.undo, maxRecordingDuration: .milliseconds(30)
        )
        await cappedSession.start()
        await h.hotkey.press()
        await waitUntil("the cap's stop") { await h.audio.calls.contains("stop") } // cap fires before we ever release
        await h.hotkey.release() // physically-late release must be a no-op, not a double-process
        await cappedSession.drain(handled: await h.hotkey.yielded)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world", "the late physical release must not start a second utterance")
    }

    // MARK: DS-13 — emoji/combining marks survive normalise + inject intact

    func test_DS13_emojiAndCombiningMarksSurviveIntact() async {
        let transcriber = FixtureTranscriber([.text("café 🎉 done")])
        let h = makeHarness(transcriber: transcriber)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "café 🎉 done")
        XCTAssertEqual(injected.count, "café 🎉 done".count)
    }

    // MARK: DS-14/15/16/17 — guarded scratch-that

    func test_DS14_scratchThatUndoesWithinGuard() async {
        let context = FakeContextProvider(makeTestContext(bundleID: "com.test.app"))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 1)
    }

    /// A host without undo (the `sotto` CLI) turns commands off: "scratch that" is dictated text.
    func test_DS14c_voiceCommandsOffTypesScratchThat() async {
        let context = FakeContextProvider(makeTestContext(bundleID: "com.test.app"))
        let transcriber = FixtureTranscriber([.text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context, voiceCommands: false)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(injected, "scratch that")
        XCTAssertEqual(undoCalls, 0)
    }

    func test_DS14b_secondScratchThatIsRefused() async {
        let context = FakeContextProvider(makeTestContext(bundleID: "com.test.app"))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context)
        let states = await collectStates(h)
        await h.session.start()
        for _ in 0..<3 {
            await h.hotkey.press(); await h.hotkey.release()
            await settle(h)
        }
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 1, "a second ⌘Z would undo text Sotto didn't write")
        let undoStates = await states.settled().filter { $0 == .undone || $0 == .error(.undoRefused) }
        XCTAssertEqual(undoStates, [.undone, .error(.undoRefused)])
    }

    func test_DS06b_appWithoutElementPastesOnceAndKeepsClipboard() async {
        let context = FakeContextProvider(makeTestContext(bundleID: "com.google.Chrome", hasTarget: false, axGranted: true))
        let h = makeHarness(context: context)
        let states = await collectStates(h)
        await runUtterance(h)
        let axCalls = await h.ax.calls.count
        let pasteText = await h.paste.injectedText()
        let unicodeCalls = await h.unicode.calls.count
        XCTAssertEqual(axCalls, 0)
        XCTAssertEqual(pasteText, "hello world")
        XCTAssertEqual(unicodeCalls, 0, "never unicode-type into an unknown focus")
        let settled = await states.settled()
        XCTAssertEqual(settled.suffix(2), [.degraded(.copiedNoTarget), .idle])
    }

    func test_DS15b_terminalUndoRefusedWithoutElement() async {
        let context = FakeContextProvider(makeTestContext(bundleID: "com.apple.Terminal", isTerminalClass: true, hasTarget: false))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 0, "terminal menus take ⌘Z; nothing reaches the prompt")
        let settled = await states.settled()
        XCTAssertTrue(settled.contains(.error(.undoRefused)))
        XCTAssertFalse(settled.contains(.undone))
    }

    func test_DS15c_terminalUndoRefusedEvenWithin30s() async {
        let clock = TestClock()
        let context = FakeContextProvider(makeTestContext(bundleID: "com.mitchellh.ghostty", isTerminalClass: true))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scrap stat")])
        let h = makeHarness(transcriber: transcriber, context: context, clock: clock)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        clock.advance(.seconds(5))
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 0, "even same bundle and element: a terminal's ⌘Z isn't an undo")
    }

    func test_DS15d_terminalUndoRefusedAfter30s() async {
        let clock = TestClock()
        let context = FakeContextProvider(makeTestContext(bundleID: "com.mitchellh.ghostty", isTerminalClass: true, hasTarget: false))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context, clock: clock)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        clock.advance(.seconds(31))
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 0)
    }

    func test_WD01_wholeDeliveryInjectsOnceAfterStreamEnds() async {
        let backend = FixtureBackend(steps: [.init("Send "), .init("it ", after: .milliseconds(10)), .init("Wednesday.", after: .milliseconds(10))])
        let h = makeHarness(backend: backend, coalescerConfig: CoalescerConfig(delivery: .whole, flushInterval: .milliseconds(5), firstTokenTimeout: .milliseconds(500), stallTimeout: .milliseconds(300)))
        await runUtterance(h)
        let calls = await h.ax.calls
        XCTAssertEqual(calls.map(\.text), ["Send it Wednesday."], "one write for the whole utterance")
    }

    func test_WD02_wholeDeliveryStallTypesFullRaw() async {
        let backend = FixtureBackend(steps: [.init("Send "), .init("never", after: .seconds(5))])
        let transcriber = FixtureTranscriber([.text("send it wednesday")])
        let h = makeHarness(transcriber: transcriber, backend: backend, coalescerConfig: CoalescerConfig(delivery: .whole, flushInterval: .milliseconds(5), firstTokenTimeout: .milliseconds(300), stallTimeout: .milliseconds(60)))
        let states = await collectStates(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "send it wednesday", "a stall before the single write types the whole raw transcript")
        let settled = await states.settled()
        XCTAssertTrue(settled.contains(.degraded(.rawTyped)), "\(settled)")
    }

    // MARK: NL — spoken lists land as real lines (SPEC §14); only the terminal sanitiser strips them

    static let listTokens = ["Notes from the vet:  \n", "1. Booster ", "shot  \n", "2. No stairs"]
    static let list = "Notes from the vet:\n1. Booster shot\n2. No stairs"
    static let whole = CoalescerConfig(delivery: .whole, flushInterval: .milliseconds(5), firstTokenTimeout: .milliseconds(500), stallTimeout: .milliseconds(300))

    private func listBackend() -> FixtureBackend {
        FixtureBackend(steps: Self.listTokens.map { .init($0) })
    }

    func test_NL01_axTargetGetsRealNewlines() async {
        let h = makeHarness(backend: listBackend(), coalescerConfig: Self.whole)
        await runUtterance(h)
        let calls = await h.ax.calls
        XCTAssertEqual(calls.map(\.text), [Self.list])
    }

    func test_NL02_pasteAndClipboardPathsKeepNewlines() async {
        let paste = makeHarness(backend: listBackend(), context: FakeContextProvider(makeTestContext(bundleID: "com.google.Chrome", hasTarget: false)), coalescerConfig: Self.whole)
        await runUtterance(paste)
        let pasted = await paste.paste.injectedText()
        XCTAssertEqual(pasted, Self.list)

        let clip = makeHarness(backend: listBackend(), context: FakeContextProvider(makeTestContext(bundleID: nil, hasTarget: false)), coalescerConfig: Self.whole)
        await runUtterance(clip)
        let copied = await clip.clipboard.copied
        XCTAssertEqual(copied, [Self.list])
    }

    func test_NL03_terminalTargetIsTheOnlyPlaceNewlinesBecomeSpaces() async {
        let h = makeHarness(backend: listBackend(), context: FakeContextProvider(makeTestContext(bundleID: "com.mitchellh.ghostty", isTerminalClass: true, hasTarget: false)), coalescerConfig: Self.whole)
        await runUtterance(h)
        let typed = await h.unicode.injectedText()
        XCTAssertEqual(typed, InjectionText.sanitizeForTerminal(Self.list))
        XCTAssertEqual(typed, "Notes from the vet: 1. Booster shot 2. No stairs")
    }

    func test_DS15_scratchThatRefusedIfBundleIDChanged() async {
        let context = FakeContextProvider(makeTestContext(bundleID: "com.test.app"))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        await context.set(makeTestContext(bundleID: "com.other.app")) // user alt-tabbed
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 0)
    }

    func test_DS16_scratchThatRefusedAfter30Seconds() async {
        let clock = TestClock()
        let context = FakeContextProvider(makeTestContext(bundleID: "com.test.app"))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context, clock: clock)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        clock.advance(.seconds(31))
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 0)
    }

    func test_DS16b_scratchThatAt29SecondsStillUndoes() async {
        let clock = TestClock()
        let context = FakeContextProvider(makeTestContext(bundleID: "com.test.app"))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context, clock: clock)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        clock.advance(.seconds(29))
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 1)
    }

    func test_DS17_scratchThatRefusedIfElementChangedWithinSameApp() async {
        let context = FakeContextProvider(makeTestContext(bundleID: "com.test.app"))
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        await context.set(makeTestContext(bundleID: "com.test.app")) // same app, new element token
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 0)
    }

    func test_DS18_scratchThatNearMissIsOrdinaryDictation() async {
        let transcriber = FixtureTranscriber([.text("scratch that thought")])
        let h = makeHarness(transcriber: transcriber)
        await runUtterance(h)
        let undoCalls = await h.undo.callCount()
        let injected = await h.ax.injectedText()
        XCTAssertEqual(undoCalls, 0)
        XCTAssertEqual(injected, "scratch that thought")
    }

    // MARK: FT-01/FT-02 — mic denied / lost

    func test_FT01_micDeniedAtCaptureStartGoesToError() async {
        let audio = FixtureAudioCapture()
        await audio.setStartError(FakeError(label: "mic-denied"))
        let h = makeHarness(audio: audio)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.release()
        await settle(h)
        let axCallCount = await h.ax.callCount()
        XCTAssertEqual(axCallCount, 0)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.error(.micDenied), .idle], "no recording state is ever shown")
    }

    func test_FT01b_noInputDeviceAtStartSaysNoMicrophone() async {
        let audio = FixtureAudioCapture()
        await audio.setStartError(AudioCaptureError.noInput)
        let h = makeHarness(audio: audio)
        let states = await collectStates(h)
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.release()
        await settle(h)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.error(.micLost), .idle])
    }

    func test_FT01c_stoppedEngineSaysNoMicrophone_notAccessOff() async {
        // 0.2.0 field bug: a failed restart left the engine stopped and the press said "Microphone access is off".
        let audio = FixtureAudioCapture()
        await audio.setStartError(AudioCaptureError.engineNotRunning)
        let h = makeHarness(audio: audio)
        let states = await collectStates(h)
        await runUtterance(h)
        let settled = await states.settled()
        XCTAssertEqual(settled, [.error(.micLost), .idle])
    }

    func test_FT02_micLostMidRecordGoesToError() async {
        let audio = FixtureAudioCapture()
        await audio.setStopError(FakeError(label: "device-lost"))
        let h = makeHarness(audio: audio)
        await runUtterance(h)
        let axCallCount = await h.ax.callCount()
        XCTAssertEqual(axCallCount, 0)
    }

    // MARK: FT-03 — no first token within timeout -> inject raw, degraded

    func test_FT03_noFirstTokenWithinTimeoutInjectsRaw() async {
        let backend = FixtureBackend(steps: [.init("late", after: .milliseconds(500))])
        let h = makeHarness(backend: backend, coalescerConfig: CoalescerConfig(flushInterval: .milliseconds(20), firstTokenTimeout: .milliseconds(60), stallTimeout: .milliseconds(500)))
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "hello world")
    }

    // MARK: FT-04 — long total time with all per-token gaps small must NOT false-trigger stall

    func test_FT04_longTotalTimeWithSmallGapsDoesNotFalseStall() async {
        // Production timeouts. Total (>=1.2s) always exceeds the 1s stall timeout; each 100ms gap
        // has 10x headroom under it, so a loaded runner's late timers can't fake a stall.
        let steps = (1...12).map { FixtureBackend.Step("w\($0) ", after: .milliseconds(100)) }
        let backend = FixtureBackend(steps: steps)
        let h = makeHarness(backend: backend, coalescerConfig: CoalescerConfig(flushInterval: .milliseconds(20)))
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, (1...12).map { "w\($0) " }.joined(), "no stall, no raw fallback")
    }

    // MARK: FT-05 — STT throws mid-transcribe on a long buffer -> error, no partial injection

    func test_FT05_sttThrowsOnLongBufferInjectsNothing() async {
        let transcriber = FixtureTranscriber([.fail(FakeError(label: "stt-mid-fail"))])
        let audio = FixtureAudioCapture(buffers: [AudioBuffer(samples: Array(repeating: 0.01, count: 16_000 * 55))])
        let h = makeHarness(transcriber: transcriber, audio: audio)
        await runUtterance(h)
        let axCallCount = await h.ax.callCount()
        XCTAssertEqual(axCallCount, 0)
    }

    // MARK: TC — target classified at hotkey-down from the focused app (iTerm2 hotkey window)

    private static func panelContext(frontmost: String?, owner: String?, frontmostIsTerminal: Bool = false) -> TargetContext {
        TargetContext(bundleID: frontmost, isTerminalClass: frontmostIsTerminal, elementToken: AXElementToken(UUID()), accessibilityGranted: true, focusOwnerBundleID: owner)
    }

    func test_TC01_terminalFocusedAtPressWinsOverNonTerminalFrontmost() async {
        let transcriber = FixtureTranscriber([.text("first paragraph\n\nsecond paragraph")])
        let context = FakeContextProvider(Self.panelContext(frontmost: Self.hostBundleID, owner: "com.googlecode.iterm2"), pressApp: "com.googlecode.iterm2")
        let h = makeHarness(transcriber: transcriber, context: context)
        await runUtterance(h)
        let typed = await h.unicode.injectedText()
        let axCalls = await h.ax.callCount()
        let pasteCalls = await h.paste.callCount()
        XCTAssertEqual(typed, "first paragraph second paragraph", "a newline typed into a shell is Return")
        XCTAssertEqual(axCalls + pasteCalls, 0)
        let target = await h.unicode.calls.first?.context
        XCTAssertEqual(target?.bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(target?.isTerminalClass, true)
    }

    func test_TC02_focusMovedBetweenPressAndReleaseCopiesToClipboard() async {
        let context = FakeContextProvider(Self.panelContext(frontmost: "com.apple.Notes", owner: "com.apple.Notes"), pressApp: "com.apple.TextEdit")
        let h = makeHarness(context: context)
        let states = await collectStates(h)
        await runUtterance(h)
        let copied = await h.clipboard.copied
        let calls = await h.ax.callCount() + h.paste.callCount() + h.unicode.callCount()
        XCTAssertEqual(copied, ["hello world"])
        XCTAssertEqual(calls, 0, "never type into an app he didn't start dictating into")
        let settled = await states.settled()
        XCTAssertEqual(settled.suffix(2), [.degraded(.copiedNoTarget), .idle])
    }

    func test_TC03_unknownPressAppNeverDowngradesATerminal() async {
        for release in [
            Self.panelContext(frontmost: "com.googlecode.iterm2", owner: nil, frontmostIsTerminal: true), // frontmost says terminal
            Self.panelContext(frontmost: Self.hostBundleID, owner: "com.googlecode.iterm2"),        // focus owner says terminal
        ] {
            let transcriber = FixtureTranscriber([.text("ls\nrm -rf build")])
            let h = makeHarness(transcriber: transcriber, context: FakeContextProvider(release, pressApp: .some(nil)))
            await runUtterance(h)
            let typed = await h.unicode.injectedText()
            let axCalls = await h.ax.callCount()
            XCTAssertEqual(typed, "ls rm -rf build", "\(release)")
            XCTAssertEqual(axCalls, 0)
        }
    }

    func test_TC04_scratchThatRefusedInATerminalHotkeyWindow() async {
        let context = FakeContextProvider(Self.panelContext(frontmost: "com.apple.Safari", owner: "com.googlecode.iterm2"), pressApp: "com.googlecode.iterm2")
        let transcriber = FixtureTranscriber([.text("hello world"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, context: context)
        await h.session.start()
        for _ in 0..<2 {
            await h.hotkey.press(); await h.hotkey.release()
            await settle(h)
        }
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 0, "terminal-class targets always refuse ⌘Z")
    }

    func test_TC07_hungPressProbeMissesTheDeadlineAndTerminalStillWins() async {
        let release = Self.panelContext(frontmost: "com.googlecode.iterm2", owner: nil, frontmostIsTerminal: true)
        let transcriber = FixtureTranscriber([.text("ls\nrm -rf build")])
        let deadlines = DeadlineLog()
        // The sleeper returns at once: the deadline "elapses" without the test waiting on it.
        let h = makeHarness(transcriber: transcriber, context: HungPressProvider(release), sleep: { await deadlines.append($0) })
        let start = ContinuousClock.now
        await runUtterance(h)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "delivery never waits on the hung probe")
        let requested = await deadlines.values
        XCTAssertEqual(requested, [.milliseconds(50)])
        let typed = await h.unicode.injectedText()
        let axCalls = await h.ax.callCount()
        XCTAssertEqual(typed, "ls rm -rf build", "terminal frontmost at release still classifies terminal")
        XCTAssertEqual(axCalls, 0)
    }
}

/// A focused app that never answers the press-time probe (the probe outlives the test).
private struct HungPressProvider: TargetContextProviding {
    let context: TargetContext
    init(_ context: TargetContext) { self.context = context }
    func pressTimeApp() async -> String? {
        try? await Task.sleep(for: .seconds(3600))
        return "com.apple.TextEdit"
    }
    func currentContext(probeSecure: Bool) async -> TargetContext { context }
    func isSecureNow(_ context: TargetContext) async -> Bool { context.isSecureInput }
}

private actor DeadlineLog {
    private(set) var values: [Duration] = []
    func append(_ d: Duration) { values.append(d) }
}
