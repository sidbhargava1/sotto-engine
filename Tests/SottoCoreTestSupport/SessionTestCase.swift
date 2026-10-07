// DictationSession end-to-end harness (PLAN §7), shared by SottoCoreTests and SottoInsightsTests.
import XCTest
@_spi(Testing) import SottoCore

class SessionTestCase: XCTestCase {
    /// The host app the harness plays (DefaultInjectionPolicy: its own window frontmost is no move).
    class var hostBundleID: String { "com.example.host" }

    struct Harness {
        let session: DictationSession
        let hotkey: FakeHotkeyMonitor
        let audio: FixtureAudioCapture
        let transcriber: FixtureTranscriber
        let ax: RecordingInjector
        let paste: RecordingInjector
        let unicode: RecordingInjector
        let context: any TargetContextProviding
        let settings: InMemorySettings
        let clipboard: FakeClipboard
        let undo: FakeUndo
    }

    func makeHarness(
        transcriber: FixtureTranscriber = FixtureTranscriber([.text("hello world")]),
        backend: any CleanupBackend = RawBackend(),
        audio: FixtureAudioCapture = FixtureAudioCapture(),
        context: any TargetContextProviding = FakeContextProvider(makeTestContext()),
        axOutcomes: [InjectionOutcome] = [],
        pasteOutcomes: [InjectionOutcome] = [],
        unicodeOutcomes: [InjectionOutcome] = [],
        coalescerConfig: CoalescerConfig = CoalescerConfig(flushInterval: .milliseconds(20), firstTokenTimeout: .milliseconds(80), stallTimeout: .milliseconds(80)),
        clock: TestClock = TestClock(),
        idleSleepGrace: Duration = AudioIdleSleep.grace,
        maxRecordingDuration: Duration = .seconds(60),
        now: (@Sendable () -> ContinuousClock.Instant)? = nil,
        onTiming: @escaping @Sendable (UtteranceTiming) -> Void = { _ in },
        livePartials: Bool = true,
        displayGate: @escaping @Sendable () async -> Bool = { true },
        dictionary: [DictionaryTerm] = [],
        settings initial: Settings = Settings(),
        history: any HistoryRecording = NoHistory(),
        undoResult: Bool = true,
        wallClock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Deadline.Sleeper = Deadline.realSleep,
        chain: ((_ ax: RecordingInjector, _ paste: RecordingInjector, _ unicode: RecordingInjector) -> InjectorChain)? = nil,
        injectionPolicy: (any InjectionPolicy)? = nil,
        voiceCommands: Bool = true
    ) -> Harness {
        let hotkey = FakeHotkeyMonitor()
        let ax = RecordingInjector(outcomes: axOutcomes)
        let paste = RecordingInjector(outcomes: pasteOutcomes)
        let unicode = RecordingInjector(outcomes: unicodeOutcomes)
        let settings = InMemorySettings(initial)
        let clipboard = FakeClipboard()
        let undo = FakeUndo(result: undoResult)
        let session = DictationSession(
            hotkey: hotkey,
            audio: audio,
            transcriber: transcriber,
            cleanup: backend,
            injectors: chain?(ax, paste, unicode) ?? InjectorChain(ax: ax, paste: paste, unicode: unicode),
            injectionPolicy: injectionPolicy ?? DefaultInjectionPolicy(hostBundleID: Self.hostBundleID),
            contextProvider: context,
            dictionaryStore: InMemoryDictionaryStore(dictionary),
            settingsStore: settings,
            clipboard: clipboard,
            undo: undo,
            history: history,
            coalescerConfig: coalescerConfig,
            maxRecordingDuration: maxRecordingDuration,
            idleSleepGrace: idleSleepGrace,
            now: now ?? { clock.now() },
            wallClock: wallClock,
            sleep: sleep,
            onTiming: onTiming,
            livePartials: livePartials,
            displayGate: displayGate,
            voiceCommands: voiceCommands
        )
        return Harness(session: session, hotkey: hotkey, audio: audio, transcriber: transcriber, ax: ax, paste: paste, unicode: unicode, context: context, settings: settings, clipboard: clipboard, undo: undo)
    }

    func collectStates(_ h: Harness) async -> StateLog {
        let log = StateLog()
        let stream = await h.session.stateUpdates()
        Task { for await state in stream { log.append(state) } }
        return log
    }

    /// Waits for every hotkey event yielded so far to be handled and the pipeline to go quiet.
    func settle(_ h: Harness) async {
        await h.session.drain(handled: await h.hotkey.yielded)
    }

    /// Drives one press/release and waits for the whole pipeline to settle.
    func runUtterance(_ h: Harness) async {
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.release()
        await settle(h)
    }

}
