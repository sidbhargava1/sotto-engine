// DictationSession end-to-end harness (PLAN §7), shared by SottoCoreTests and SottoInsightsTests.
import XCTest
@_spi(Testing) import SottoCore

class SessionTestCase: XCTestCase {
    /// The host app the harness plays (DefaultInjectionPolicy: its own window frontmost is no move).
    class var hostBundleID: String { "com.example.host" }

    /// Stall timers far beyond any fake's delay, so a slow runner can't turn a test's cleanup into
    /// the raw fallback. Tests of the stall path pass their own config.
    static let patientCoalescer = CoalescerConfig(flushInterval: .milliseconds(20), firstTokenTimeout: .seconds(5), stallTimeout: .seconds(5))

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
        let clock: TestClock
        /// Voice commands: the fake executor, and the inputs and catalogue the session reads.
        let executor: FakeCommandExecutor
        let commandInputs: CommandBox<CommandInputs>
        let catalog: CommandBox<CommandCatalog>
    }

    func makeHarness(
        transcriber: FixtureTranscriber = FixtureTranscriber([.text("hello world")]),
        backend: any CleanupBackend = RawBackend(),
        audio: FixtureAudioCapture = FixtureAudioCapture(),
        context: any TargetContextProviding = FakeContextProvider(makeTestContext()),
        axOutcomes: [InjectionOutcome] = [],
        pasteOutcomes: [InjectionOutcome] = [],
        unicodeOutcomes: [InjectionOutcome] = [],
        coalescerConfig: CoalescerConfig = SessionTestCase.patientCoalescer,
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
        voiceCommands: Bool = true,
        commandInputs initialInputs: CommandInputs = .disabled,
        commandCatalog initialCatalog: CommandCatalog = CommandCatalog(),
        executor: FakeCommandExecutor = FakeCommandExecutor(),
        maxCommandRecordingDuration: Duration = .seconds(15),
        commandSleep: Deadline.Sleeper? = nil
    ) -> Harness {
        let commandInputs = CommandBox(initialInputs)
        let catalog = CommandBox(initialCatalog)
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
            voiceCommands: voiceCommands,
            commandInputs: { commandInputs.value },
            commandCatalog: { catalog.value },
            commandExecutor: executor,
            commandSleep: commandSleep ?? { await clock.sleep($0) },
            maxCommandRecordingDuration: maxCommandRecordingDuration
        )
        return Harness(session: session, hotkey: hotkey, audio: audio, transcriber: transcriber, ax: ax, paste: paste, unicode: unicode, context: context, settings: settings, clipboard: clipboard, undo: undo, clock: clock, executor: executor, commandInputs: commandInputs, catalog: catalog)
    }

    func collectPhases(_ h: Harness) async -> PhaseLog {
        let log = PhaseLog()
        let stream = await h.session.commandPhaseUpdates()
        Task { for await phase in stream { log.append(phase) } }
        return log
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

/// Polls `condition` until it holds, failing after `timeout`. For progress a test can't await
/// directly; the bound is a hang guard, never the expected latency.
func waitUntil(_ what: String, timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    if await condition() { return }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}
