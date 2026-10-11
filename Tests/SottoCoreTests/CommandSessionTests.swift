// Voice commands through a full DictationSession (command spec §12 "Session tests" and the QA
// must-haves). Fakes only. The "never a keystroke" rule is asserted on every command path: zero
// injector, undo (the only key sender) and pasteboard calls, and no History offer.
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

class CommandTestCase: SessionTestCase {
    typealias T = CommandGrammarTests
    static let allOn = CommandInputs(commandsEnabled: true, commandKeyEnabled: true, prefixEnabled: true)

    // MARK: helpers

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// Cleanup that must never be asked on a command path (and fails if it is).
    struct CountingFailingBackend: CleanupBackend {
        let counter: Counter
        func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
            counter.bump()
            return AsyncThrowingStream { $0.finish(throwing: FakeError(label: "cleanup down")) }
        }
    }

    struct Rig {
        let h: Harness
        let phases: PhaseLog
        let states: StateLog
        let history: RecordingHistory
        let gate: Counter
        let cleanup: Counter
    }

    func rig(
        _ texts: [FixtureTranscriber.Behavior], inputs: CommandInputs = CommandSessionTests.allOn,
        catalog: CommandCatalog = T.catalog(), dictionary: [DictionaryTerm] = [],
        audio: FixtureAudioCapture = FixtureAudioCapture(), settings: Settings = Settings(),
        transcriber: FixtureTranscriber? = nil, executor: FakeCommandExecutor = FakeCommandExecutor(),
        idleSleepGrace: Duration = AudioIdleSleep.grace, sleeper: ManualSleeper? = nil
    ) async -> Rig {
        let history = RecordingHistory()
        let gate = Counter(), cleanup = Counter()
        let sleepFn: Deadline.Sleeper? = sleeper.map { s in { @Sendable d in await s.sleep(d) } }
        let h = makeHarness(
            transcriber: transcriber ?? FixtureTranscriber(texts), backend: CountingFailingBackend(counter: cleanup),
            audio: audio, idleSleepGrace: idleSleepGrace,
            displayGate: { gate.bump(); return true }, dictionary: dictionary, settings: settings, history: history,
            commandInputs: inputs, commandCatalog: catalog, executor: executor,
            commandSleep: sleepFn)
        let phases = await collectPhases(h)
        let states = await collectStates(h)
        await h.session.start()
        return Rig(h: h, phases: phases, states: states, history: history, gate: gate, cleanup: cleanup)
    }

    func isConfirmPending(_ p: CommandPhase) -> Bool { if case .confirmPending = p { true } else { false } }

    func holdCommandKey(_ r: Rig) async {
        await r.h.hotkey.pressCommand()
        await r.h.hotkey.releaseCommand()
    }

    /// Hold and release the command key, answering a confirm with a tap when `tap` is set.
    func speakCommand(_ r: Rig, tap: Bool = false) async {
        await holdCommandKey(r)
        if tap {
            await waitUntil("confirm pending") { r.phases.snapshot().contains(where: self.isConfirmPending) }
            await holdCommandKey(r)
        }
        await settle(r.h)
    }

    func speakDictation(_ r: Rig) async {
        await r.h.hotkey.press()
        await r.h.hotkey.release()
        await settle(r.h)
    }

    func expectPhases(_ r: Rig, _ expected: [CommandPhase], _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while r.phases.snapshot() != expected, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(r.phases.snapshot(), expected, msg, file: file, line: line)
    }

    /// The "never a keystroke" rule: no text, no ⌘Z, no pasteboard, nothing for History.
    func assertNoSideEffects(_ r: Rig, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let typed = await [r.h.ax.callCount(), r.h.paste.callCount(), r.h.unicode.callCount()]
        XCTAssertEqual(typed, [0, 0, 0], "injector calls \(msg)", file: file, line: line)
        let undo = await r.h.undo.callCount()
        XCTAssertEqual(undo, 0, "key events \(msg)", file: file, line: line)
        let pasted = await r.h.clipboard.copied
        XCTAssertTrue(pasted.isEmpty, "pasteboard \(msg)", file: file, line: line)
        XCTAssertTrue(r.history.offers.isEmpty && r.history.records.isEmpty, "History \(msg)", file: file, line: line)
        XCTAssertEqual(r.cleanup.value, 0, "cleanup asked \(msg)", file: file, line: line)
    }

    /// What a transcript should produce, derived from the router on the same catalogue.
    func expectedPhases(_ route: CommandRoute, prefix: Bool, tap: Bool) -> [CommandPhase] {
        var out: [CommandPhase] = prefix ? [.recognisedAsCommand] : [.listening(.command), .working]
        switch route {
        case .failed(let f): out.append(.failed(f))
        case .resolved(.runShortcut(let shortcut)):
            if shortcut.askFirst { out.append(.confirmPending(shortcut: shortcut.name)) }
            out += [.running, .finished(.done)]
        case .resolved(let c): out += [.acting(c), .finished(.done)]
        }
        return out
    }

    func route(_ heard: String, dictationKey: Bool, catalog: CommandCatalog, prefixOn: Bool = true) -> CommandRoute? {
        if dictationKey {
            switch CommandRouter.routeDictationKey(heard, catalog: catalog, prefixEnabled: prefixOn) {
            case .command(let c): return .resolved(c)
            case .commandError(let f): return .failed(f)
            case .dictation, .scratchThat: return nil
            }
        }
        switch CommandRouter.routeCommandKey(heard, catalog: catalog) {
        case .resolved(let c): return .resolved(c)
        case .failed(let f): return .failed(f)
        }
    }

    func runRow(_ heard: String, dictationKey: Bool, catalog: CommandCatalog, prefixOn: Bool = true, dictionary: [DictionaryTerm] = [], label: String, file: StaticString = #filePath, line: UInt = #line) async {
        var inputs = Self.allOn
        inputs.prefixEnabled = prefixOn
        let r = await rig([.text(heard)], inputs: inputs, catalog: catalog, dictionary: dictionary)
        let routed = route(DictionaryRewriter.rewrite(heard, terms: dictionary), dictationKey: dictationKey, catalog: catalog, prefixOn: prefixOn)
        if let routed {
            var tap = false
            if case .resolved(.runShortcut(let s)) = routed, s.askFirst { tap = true }
            if dictationKey {
                await speakDictation(r)
                if tap {
                    await waitUntil("confirm pending") { r.phases.snapshot().contains(where: self.isConfirmPending) }
                    await holdCommandKey(r)
                    await settle(r.h)
                }
            } else {
                await speakCommand(r, tap: tap)
            }
            await expectPhases(r, expectedPhases(routed, prefix: dictationKey, tap: tap), label, file: file, line: line)
            await assertNoSideEffects(r, label, file: file, line: line)
            let ran = await r.h.executor.callCount()
            if case .resolved = routed { XCTAssertEqual(ran, 1, label, file: file, line: line) } else { XCTAssertEqual(ran, 0, label, file: file, line: line) }
            XCTAssertEqual(r.gate.value, dictationKey ? 1 : 0, "display gate asked only for dictation \(label)", file: file, line: line)
        } else {
            XCTAssertTrue(dictationKey, "\(label): the command key always produces a route", file: file, line: line)
            await speakDictation(r)
            XCTAssertEqual(r.phases.snapshot(), [], label, file: file, line: line)
            let ran = await r.h.executor.callCount()
            XCTAssertEqual(ran, 0, label, file: file, line: line)
            // Dictation falls through exactly as before: the text lands (or "scratch that" is refused).
            let typed = await r.h.ax.injectedText()
            if CommandParser.parse(heard) == .scratchThat {
                let undo = await r.h.undo.callCount()
                XCTAssertEqual([typed, "\(undo)"], ["", "0"], label, file: file, line: line)
            } else {
                XCTAssertEqual(typed, heard.trimmingCharacters(in: .whitespacesAndNewlines), label, file: file, line: line)
            }
        }
    }

}

final class CommandSessionTests: CommandTestCase {
    // MARK: the table and the QA rows, through a session

    func test_allTableRowsThroughASession() async {
        for row in T.rows {
            var inputs = Self.allOn
            inputs.prefixEnabled = row.prefixOn
            await runRow(row.heard, dictationKey: row.dictationKey, catalog: T.catalog(shortcuts: row.shortcutsOn),
                         prefixOn: row.prefixOn, label: "row \(row.n): \(row.heard)")
            _ = inputs
        }
    }

    func test_row27_heardAsRewriteRunsBeforeTheRouter() async {
        let fleet = CatalogApp(name: "FleetView", id: "id.fleet")
        var catalog = T.catalog()
        catalog.apps.append(fleet)
        await runRow("open fleet view", dictationKey: false, catalog: catalog,
                     dictionary: [DictionaryTerm("FleetView (fleet view)")], label: "row 27")
        let r = await rig([.text("open fleet view")], catalog: catalog, dictionary: [DictionaryTerm("FleetView (fleet view)")])
        await speakCommand(r)
        let calls = await r.h.executor.calls
        XCTAssertEqual(calls, [.open(fleet, state: .notRunning)])
    }

    static let qaStrings = [
        "Open Slack.", "open x-code", "open X Code!", "OPEN   SLACK", "Sotto. Please open Slack, for me.",
        "hey can you please open Slack up", "please", "can you", "Sotto", "so to open Slack", "So to open Slack",
        "Sotto, please open Slack", "Sotto, could you please open Slack", "Sotto open Slak.", "soto open slak",
        "Sotto open Slak app", "Sotto open the Slak app", "open the Slak app please", "open one two three four",
        "open one two three four five", "Sotto open one two", "Sotto open one two three", "open Google Chrome",
        "open google", "open Mail", "switch to Safari", "hide Slack", "hide Slak", "open standup",
        "switch to standup", "open folder standup", "hide invoices", "open cafe notes", "open resume", "run x",
        "I said Sotto open Slack", "open .", "open", "run weekly update",
        String(repeating: "word ", count: 5_000), "open " + String(repeating: "a", count: 100_000),
    ]

    func test_qaRowsThroughASession_everyCatalogue() async {
        var rich = T.catalog()
        rich.apps += [CatalogApp(name: "Café Notes", id: "id.cafe"), CatalogApp(name: "Résumé", id: "id.resume"),
                      CatalogApp(name: "Google", id: "id.google"), CatalogApp(name: "📝 日本語", id: "id.cjk")]
        rich.links.append(CatalogItem(spokenName: "safari", target: "opaque-link-2")) // link and app share a name
        rich.frontmostAppID = T.safari.id
        let empty = CommandCatalog(shortcutsEnabled: true)
        for (name, catalog) in [("rich", rich), ("empty", empty)] {
            for heard in Self.qaStrings {
                for dictationKey in [false, true] {
                    await runRow(heard, dictationKey: dictationKey, catalog: catalog,
                                 label: "\(name) \(dictationKey ? "D" : "K"): \(heard.prefix(40))")
                }
            }
        }
    }

    // MARK: command press shape

    func test_commandPressNeverUsesTheDisplayGateOrPartials() async {
        let events = EventLog<String>()
        let audio = FixtureAudioCapture(events: events)
        let snapshot = PartialTranscript(stable: "open Slack", volatile: "", audioSeconds: 1)
        let transcriber = FixtureTranscriber([.text("open Slack")], partials: .perChunk([snapshot]), events: events)
        let r = await rig([], audio: audio, transcriber: transcriber)
        let partials = PartialLog(), raw = RawLog()
        let partialStream = await r.h.session.partialUpdates()
        Task { for await p in partialStream { partials.append(p) } }
        let rawStream = await r.h.session.rawTranscriptUpdates()
        Task { for await text in rawStream { raw.append(text) } }

        await r.h.hotkey.pressCommand()
        await waitUntil("recording") { await audio.calls.contains("start") }
        audio.pushChunk()
        await r.h.hotkey.releaseCommand()
        await settle(r.h)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(r.gate.value, 0, "the display gate is never asked")
        XCTAssertFalse(events.snapshot().contains("partials.start"), "no partial pass is started")
        XCTAssertEqual(partials.snapshot().count, 0, "not even the closing nil")
        XCTAssertEqual(raw.snapshot(), [], "heard text never reaches the bubble")
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 1)
    }

    func test_commandPressEventsAndNoTranscriptInAnyEvent() async {
        let heard = "send the report to Maria"
        let r = await rig([.text(heard)])
        await speakCommand(r)
        await expectPhases(r, [.listening(.command), .working, .failed(.unrecognised)])
        let states = await r.states.settled()
        XCTAssertEqual(states, [.recording, .transcribing, .idle])
        for event in r.phases.snapshot().map({ "\($0)" }) + states.map({ "\($0)" }) {
            XCTAssertFalse(event.contains("Maria"), "no event carries the transcript: \(event)")
        }
    }

    func test_dictationKeyAlwaysDictates_andEmitsNoCommandListening() async {
        let r = await rig([.text("hello there")])
        await speakDictation(r)
        let typed = await r.h.ax.injectedText()
        XCTAssertEqual(typed, "hello there")
        XCTAssertEqual(r.phases.snapshot(), [])
    }

    func test_commandPressWorksWithCleanupFailingAndTouchesNothing() async {
        let r = await rig([.text("open Slack")]) // every cleanup request would throw
        await speakCommand(r)
        await expectPhases(r, [.listening(.command), .working, .acting(.open(T.slack, state: .running)), .finished(.done)])
        await assertNoSideEffects(r) // includes "cleanup was never asked"
    }

    func test_executorFailureOutcomeIsReportedOnce() async {
        let r = await rig([.text("open Mail")], executor: FakeCommandExecutor(outcome: .launchFailed))
        await speakCommand(r)
        await expectPhases(r, [.listening(.command), .working,
                               .acting(.open(T.mail, state: .notRunning)), .finished(.launchFailed)])
    }

    // MARK: ignored presses

    func test_disabledCommandsIgnoreTheCommandKey() async {
        let cases: [(String, CommandInputs)] = [
            ("master off", CommandInputs(commandsEnabled: false, commandKeyEnabled: true, prefixEnabled: true)),
            ("key off", CommandInputs(commandsEnabled: true, commandKeyEnabled: false, prefixEnabled: true)),
        ]
        for (label, inputs) in cases {
            var settings = Settings()
            settings.paused = true
            let r = await rig([.text("open Slack")], inputs: inputs, settings: settings)
            await speakCommand(r)
            let calls = await r.h.audio.calls
            XCTAssertEqual(calls, [], label)
            XCTAssertEqual(r.phases.snapshot(), [], label)
            XCTAssertEqual(r.states.snapshot(), [], label)
            let ran = await r.h.executor.callCount()
            XCTAssertEqual(ran, 0, label)
            let paused = await r.h.settings.load().paused
            XCTAssertTrue(paused, "an ignored press does not unpause (\(label))")
        }
    }

    func test_pauseThenCommandPressWakesTheEngine() async {
        var settings = Settings()
        settings.paused = true
        let r = await rig([.text("open Slack")], settings: settings, idleSleepGrace: .milliseconds(40))
        // Warm up and let the engine go to sleep, as after a Pause.
        await r.h.session.scheduleIdleSleep()
        await waitUntil("idle sleep") { await r.h.audio.calls.contains("sleep") }
        await speakCommand(r)
        let calls = await r.h.audio.calls
        XCTAssertEqual(calls, ["sleep", "wake", "start", "stop"])
        let paused = await r.h.settings.load().paused
        XCTAssertFalse(paused)
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 1)
    }

    func test_shortTapWithNoAudioIsDidntCatchThat() async {
        let audio = FixtureAudioCapture(buffers: [AudioBuffer(samples: [])])
        let r = await rig([], audio: audio)
        await speakCommand(r)
        let states = await r.states.settled()
        XCTAssertEqual(states, [.recording, .transcribing, .error(.sttFailed), .idle])
        XCTAssertEqual(r.phases.snapshot(), [.listening(.command), .working], "no outcome event: the error state speaks")
        await assertNoSideEffects(r)
    }

    func test_keyDownDuringColdWakeDoesNotDoubleStart() async {
        let r = await rig([.text("open Slack")], idleSleepGrace: .milliseconds(30))
        await r.h.session.scheduleIdleSleep()
        await waitUntil("idle sleep") { await r.h.audio.calls.contains("sleep") }
        await r.h.hotkey.pressCommand()
        await r.h.hotkey.pressCommand() // key repeat or a bounce while the wake is in flight
        await r.h.hotkey.releaseCommand()
        await settle(r.h)
        let calls = await r.h.audio.calls
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1, "\(calls)")
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 1)
    }

    func test_micErrorOnCommandKeyEmitsTheSameStatesAsDictation() async {
        for error: Error in [AudioCaptureError.noInput, FakeError(label: "denied")] {
            let audio = FixtureAudioCapture()
            await audio.setStartError(error)
            let rc = await rig([], audio: audio)
            await holdCommandKey(rc)
            await settle(rc.h)
            let audio2 = FixtureAudioCapture()
            await audio2.setStartError(error)
            let rd = await rig([], audio: audio2)
            await rd.h.hotkey.press()
            await rd.h.hotkey.release()
            await settle(rd.h)
            let a = await rc.states.settled(), b = await rd.states.settled()
            XCTAssertEqual(a, b)
            XCTAssertEqual(rc.phases.snapshot(), [], "no command phase before capture started")
        }
    }
}
