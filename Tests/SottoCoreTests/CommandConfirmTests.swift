// The confirm state machine, races, the 15 s cap, the prefix path and the scratch-that guard.
// Time is the shared TestClock; nothing here sleeps for real except to let a bug have room.
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

final class CommandConfirmTests: CommandTestCase {
    let shortcut = ResolvedCommand.runShortcut(CatalogShortcut(name: "Weekly update", askFirst: true))

    func count(_ r: Rig, _ match: (CommandPhase) -> Bool) -> Int { r.phases.snapshot().filter(match).count }
    func isCancelled(_ p: CommandPhase) -> Bool { p == .cancelled }
    func isRunning(_ p: CommandPhase) -> Bool { p == .running }

    /// A command-key shortcut waiting for its tap.
    func pendingRig(inputs: CommandInputs = CommandSessionTests.allOn, texts: [FixtureTranscriber.Behavior] = [.text("run weekly update")]) async -> Rig {
        let r = await rig(texts, inputs: inputs)
        await holdCommandKey(r)
        await waitUntil("confirm pending") { r.phases.snapshot().contains(where: self.isConfirmPending) }
        await waitUntil("timer armed") { r.h.clock.pendingSleeps >= 1 }
        return r
    }

    // MARK: confirm

    func test_tapConfirms_runsOnce_noRecording_releaseIgnored() async {
        let r = await pendingRig()
        await r.h.hotkey.pressCommand() // the tap
        await waitUntil("executor called") { await r.h.executor.callCount() == 1 }
        let phasesAtTap = r.phases.snapshot()
        await r.h.hotkey.releaseCommand() // its release
        await settle(r.h)
        XCTAssertEqual(r.phases.snapshot(), phasesAtTap, "the matching release emits nothing")
        XCTAssertEqual(phasesAtTap, [.listening(.command), .working, .confirmPending(shortcut: "Weekly update"), .running, .finished(.done)])
        let calls = await r.h.audio.calls
        XCTAssertEqual(calls, ["start", "stop"], "the tap starts no recording")
        let ran = await r.h.executor.calls
        XCTAssertEqual(ran, [shortcut])
        r.h.clock.advance(.seconds(30))
        await settle(r.h)
        XCTAssertEqual(count(r, isCancelled), 0, "the timer is gone")
        await assertNoSideEffects(r)
    }

    func test_dictationPressCancelsConfirm_thenDictatesNormally() async {
        let r = await pendingRig(texts: [.text("run weekly update"), .text("meeting notes")])
        await r.h.hotkey.press()
        await r.h.hotkey.release()
        await settle(r.h)
        XCTAssertEqual(r.phases.snapshot().suffix(2), [.confirmPending(shortcut: "Weekly update"), .cancelled])
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 0)
        let typed = await r.h.ax.injectedText()
        XCTAssertEqual(typed, "meeting notes")
        let states = await r.states.settled()
        XCTAssertFalse(states.contains(.error(.sttFailed)), "no empty dictation and no \"Didn't catch that\": \(states)")
        // The cancelled confirm's idle must not land over the dictation that just started.
        let firstDictation = states.lastIndex(of: .recording)!
        XCTAssertFalse(states[firstDictation...].prefix(while: { $0 != .transcribing }).contains(.idle), "\(states)")
        XCTAssertEqual(count(r, { $0 == .cancelled }), 1)
    }

    func test_timeout_8s_nothingBefore() async {
        let r = await pendingRig()
        r.h.clock.advance(.milliseconds(7_990))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(count(r, isCancelled), 0, "nothing at 7.99 s")
        r.h.clock.advance(.milliseconds(10))
        await settle(r.h)
        await expectPhases(r, [.listening(.command), .working, .confirmPending(shortcut: "Weekly update"), .cancelled])
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 0)
        await assertNoSideEffects(r)
    }

    func test_timeout_10s_withVoiceOver() async {
        var inputs = Self.allOn
        inputs.voiceOverRunning = true
        let r = await pendingRig(inputs: inputs)
        r.h.clock.advance(.seconds(8))
        r.h.clock.advance(.milliseconds(1_990))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(count(r, isCancelled), 0, "still waiting at 9.99 s")
        r.h.clock.advance(.milliseconds(10))
        await settle(r.h)
        XCTAssertEqual(count(r, isCancelled), 1)
    }

    func test_tapThenTimeout_exactlyOneOutcome() async {
        let r = await pendingRig()
        await r.h.hotkey.pressCommand()
        r.h.clock.advance(.seconds(8))
        await r.h.hotkey.releaseCommand()
        await settle(r.h)
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(count(r, isCancelled), 0)
        XCTAssertEqual(count(r, isRunning), 1)
    }

    func test_timeoutThenTap_exactlyOneOutcome_noRun() async {
        let r = await pendingRig()
        r.h.clock.advance(.seconds(8))
        await waitUntil("cancelled") { self.count(r, self.isCancelled) == 1 }
        await r.h.hotkey.pressCommand() // too late: this is a fresh command press, not a confirm
        await r.h.hotkey.releaseCommand()
        await settle(r.h)
        let ran = await r.h.executor.calls
        XCTAssertEqual(ran, [], "never a run after the timeout")
        XCTAssertEqual(count(r, isCancelled), 1)
        XCTAssertEqual(count(r, isRunning), 0)
    }

    func test_tapAndTimeoutAtTheSameInstant_neverBothOutcomes() async {
        for i in 0..<25 {
            let r = await pendingRig()
            async let tap: Void = r.h.hotkey.pressCommand()
            async let fire: Void = r.h.clock.advance(.seconds(8))
            _ = await (tap, fire)
            await r.h.hotkey.releaseCommand()
            // Whoever won, the loser must not leave a second outcome behind.
            await waitUntil("an outcome") { self.count(r, self.isCancelled) + self.count(r, self.isRunning) >= 1 }
            await settle(r.h)
            let ran = await r.h.executor.callCount()
            XCTAssertEqual(self.count(r, self.isCancelled) + self.count(r, self.isRunning), 1, "iteration \(i): \(r.phases.snapshot())")
            XCTAssertEqual(ran, self.count(r, self.isRunning), "iteration \(i)")
        }
    }

    func test_tapOutcomesNeverRunTwice_whenTappedTwice() async {
        let r = await pendingRig()
        await r.h.hotkey.pressCommand()
        await r.h.hotkey.releaseCommand()
        await settle(r.h)
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 1)
    }

    func test_tearDownReleasesAPendingConfirm_once() async {
        let r = await pendingRig()
        await r.h.session.stopMonitoring()
        await settle(r.h)
        XCTAssertEqual(count(r, isCancelled), 1)
        r.h.clock.advance(.seconds(30))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(count(r, isCancelled), 1, "the timer cannot cancel it a second time")
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 0)
    }

    func test_tearDownWhileExecutorInFlight_oneCompletion_guardCleared() async {
        let executor = FakeCommandExecutor()
        await executor.hold()
        let r = await rig([.text("hello world"), .text("open Slack")], executor: executor)
        await speakDictation(r) // seeds the scratch-that target
        let armed = await r.h.session.scratchGuardArmed()
        XCTAssertTrue(armed)
        await holdCommandKey(r)
        await waitUntil("executor in flight") { await executor.callCount() == 1 }
        await r.h.session.stopMonitoring()
        await executor.release()
        await settle(r.h)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(count(r, { if case .finished = $0 { true } else { false } }), 1, "no double completion")
        XCTAssertEqual(count(r, isCancelled), 0)
        let stillArmed = await r.h.session.scratchGuardArmed()
        XCTAssertFalse(stillArmed)
    }

    func test_confirmKeyUnavailable_onPrefixPath() async {
        var inputs = Self.allOn
        inputs.confirmKeyAvailable = false
        let r = await rig([.text("Sotto, run weekly update")], inputs: inputs)
        await speakDictation(r)
        await expectPhases(r, [.recognisedAsCommand, .failed(.confirmKeyUnavailable)])
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 0)
        let typed = await r.h.ax.injectedText()
        XCTAssertEqual(typed, "")
        XCTAssertEqual(r.phases.snapshot().filter { $0 == .cancelled }.count, 0)
    }

    func test_prefixShortcutConfirmedByCommandKeyTap() async {
        let r = await rig([.text("Sotto, run weekly update")])
        await r.h.hotkey.press()
        await r.h.hotkey.release()
        await waitUntil("confirm pending") { r.phases.snapshot().contains(where: self.isConfirmPending) }
        await holdCommandKey(r)
        await settle(r.h)
        await expectPhases(r, [.recognisedAsCommand, .confirmPending(shortcut: "Weekly update"), .running, .finished(.done)])
        await assertNoSideEffects(r)
    }

    func test_askFirstOffRunsAtOnce() async {
        var catalog = T.catalog()
        catalog.shortcuts = [CatalogShortcut(name: "Weekly update", askFirst: false)]
        let r = await rig([.text("run weekly update")], catalog: catalog)
        await speakCommand(r)
        await expectPhases(r, [.listening(.command), .working, .running, .finished(.done)])
    }

    // MARK: prefix

    func test_prefixOff_typesAsBefore_andMasterOffIgnoresPrefix() async {
        for inputs in [CommandInputs(commandsEnabled: true, prefixEnabled: false), CommandInputs(commandsEnabled: false, prefixEnabled: true), .disabled] {
            let r = await rig([.text("Sotto, open Slack")], inputs: inputs)
            await speakDictation(r)
            let typed = await r.h.ax.injectedText()
            XCTAssertEqual(typed, "Sotto, open Slack")
            XCTAssertEqual(r.phases.snapshot(), [])
            let ran = await r.h.executor.callCount()
            XCTAssertEqual(ran, 0)
        }
    }

    func test_prefixIsReadAtPress() async {
        let r = await rig([.text("Sotto, open Slack")], inputs: CommandInputs(commandsEnabled: true, prefixEnabled: true))
        await r.h.hotkey.press()
        await waitUntil("recording") { await r.h.audio.calls.contains("start") }
        r.h.commandInputs.value.prefixEnabled = false // flipped mid-utterance: applies from the next press
        await r.h.hotkey.release()
        await settle(r.h)
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 1)
    }

    func test_prefixCommandTypesNothing_andRecordsNothing() async {
        let r = await rig([.text("Sotto open Slak")])
        await speakDictation(r)
        await expectPhases(r, [.recognisedAsCommand, .failed(.notFound(.app, spoken: "Slak"))])
        await assertNoSideEffects(r)
        XCTAssertEqual(r.gate.value, 1, "it was a dictation press until classified")
    }

    func test_scratchThatBeatsThePrefix() async {
        let r = await rig([.text("scratch that")])
        await speakDictation(r)
        XCTAssertEqual(r.phases.snapshot(), [])
        let states = await r.states.settled()
        XCTAssertEqual(states.last, .idle)
        XCTAssertTrue(states.contains(.error(.undoRefused)))
    }

    // MARK: scratch-that guard

    func test_scratchThatRefusedAfterEveryOutcome() async {
        let cases: [(String, String, Bool, CommandCatalog)] = [
            ("success", "open Slack", false, T.catalog()),
            ("noMatch", "send the report to Maria", false, T.catalog()),
            ("notFound", "open Slak", false, T.catalog()),
            ("ambiguous", "open google", false, T.catalog()),
            ("notRunning", "hide Mail", false, T.catalog()),
            ("shortcutsOff", "run weekly update", false, T.catalog(shortcuts: false)),
            ("prefix error", "Sotto open Slak", true, T.catalog()),
            ("prefix success", "Sotto open Slack", true, T.catalog()),
        ]
        for (label, heard, prefix, catalog) in cases {
            let r = await rig([.text("hello world"), .text(heard), .text("scratch that")], catalog: catalog)
            await speakDictation(r) // lands and arms the guard with a valid injection
            let armed = await r.h.session.scratchGuardArmed()
            XCTAssertTrue(armed, label)
            if prefix { await speakDictation(r) } else { await speakCommand(r) }
            let after = await r.h.session.scratchGuardArmed()
            XCTAssertFalse(after, label)
            await speakDictation(r) // "scratch that"
            let undo = await r.h.undo.callCount()
            XCTAssertEqual(undo, 0, "\(label): nothing sent")
            let states = await r.states.settled()
            XCTAssertTrue(states.contains(.error(.undoRefused)), "\(label): \(states)")
        }
    }

    func test_scratchThatRefusedAfterCancelledAndTimedOutConfirm() async {
        for viaTimeout in [true, false] {
            let r = await rig([.text("hello world"), .text("run weekly update"), .text("scratch that")])
            await speakDictation(r)
            await holdCommandKey(r)
            await waitUntil("confirm pending") { r.phases.snapshot().contains(where: self.isConfirmPending) }
            await waitUntil("timer armed") { r.h.clock.pendingSleeps >= 1 }
            if viaTimeout {
                r.h.clock.advance(.seconds(8))
                await settle(r.h)
            } else {
                await r.h.session.stopMonitoring()
            }
            let after = await r.h.session.scratchGuardArmed()
            XCTAssertFalse(after, "viaTimeout \(viaTimeout)")
        }
    }

    // MARK: ordering with dictation

    func dictationInCleanupThenCommand(cleanupFails: Bool) async {
        let backend = GatedBackend(tokens: ["first ", "dictation"])
        let history = RecordingHistory()
        let h = makeHarness(
            transcriber: FixtureTranscriber([.text("first dictation"), .text("open Slack")]),
            backend: cleanupFails ? CountingFailingBackend(counter: Counter()) : backend,
            audio: FixtureAudioCapture(buffers: [AudioBuffer(samples: [0.1]), AudioBuffer(samples: [0.2])]),
            history: history, commandInputs: Self.allOn, commandCatalog: T.catalog())
        let phases = await collectPhases(h)
        await h.session.start()
        await h.hotkey.press()
        await h.hotkey.release()
        if !cleanupFails {
            await backend.open() // the dictation is mid-cleanup: one token typed, the rest held
            await waitUntil("first chunk") { await h.ax.injectedText() == "first " }
        }
        await h.hotkey.pressCommand()
        await h.hotkey.releaseCommand()
        await waitUntil("command heard") { phases.snapshot().contains(.working) }
        if !cleanupFails {
            try? await Task.sleep(for: .milliseconds(30))
            let early = await h.executor.callCount()
            XCTAssertEqual(early, 0, "the command waits; it never cancels the dictation")
            await backend.openAll()
        }
        await waitUntil("command ran") { await h.executor.callCount() == 1 }
        let typed = await h.ax.injectedText()
        XCTAssertEqual(typed, cleanupFails ? "first dictation" : "first dictation", "dictation landed in full before the command ran")
        await settle(h)
        XCTAssertEqual(phases.snapshot().last, .finished(.done))
    }

    func test_commandPressDuringCleanup_dictationLandsFirst() async { await dictationInCleanupThenCommand(cleanupFails: false) }
    func test_commandPressDuringCleanup_cleanupFails_rawFallbackStillLands() async { await dictationInCleanupThenCommand(cleanupFails: true) }

    func test_commandPressDuringLinger_startsNewSession_noIdleOverIt() async {
        let r = await rig([.text("send the report to Maria"), .text("open Slack")])
        await speakCommand(r) // ends in a failure whose capsule lingers in the app
        await r.h.hotkey.pressCommand()
        await waitUntil("second recording") { r.states.snapshot().filter { $0 == .recording }.count == 2 }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(r.states.snapshot().last, .recording, "nothing from the finished command lands over the new press")
        await r.h.hotkey.releaseCommand()
        await settle(r.h)
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 1)
    }

    // MARK: 15 s cap

    func test_commandCap_14_99DoesNothing_15StopsLikeARelease() async {
        let r = await rig([.text("open Slack")])
        await r.h.hotkey.pressCommand()
        await waitUntil("cap armed") { r.h.clock.pendingSleeps == 1 }
        r.h.clock.advance(.milliseconds(14_990))
        try? await Task.sleep(for: .milliseconds(30))
        var calls = await r.h.audio.calls
        XCTAssertEqual(calls, ["start"], "still recording at 14.99 s")
        r.h.clock.advance(.milliseconds(10))
        await waitUntil("stopped") { await r.h.audio.calls.contains("stop") }
        await r.h.hotkey.releaseCommand() // the late physical release is a no-op
        await settle(r.h)
        calls = await r.h.audio.calls
        XCTAssertEqual(calls, ["start", "stop"])
        await expectPhases(r, [.listening(.command), .working, .acting(.open(T.slack, state: .running)), .finished(.done)])
        let ran = await r.h.executor.callCount()
        XCTAssertEqual(ran, 1)
    }

    func test_commandCap_releaseAtTheCap_oneUtterance() async {
        for releaseFirst in [true, false] {
            let r = await rig([.text("open Slack")])
            await r.h.hotkey.pressCommand()
            await waitUntil("cap armed") { r.h.clock.pendingSleeps == 1 }
            if releaseFirst {
                await r.h.hotkey.releaseCommand()
                r.h.clock.advance(.seconds(15))
            } else {
                r.h.clock.advance(.seconds(15))
                await r.h.hotkey.releaseCommand()
            }
            await settle(r.h)
            let calls = await r.h.audio.calls
            XCTAssertEqual(calls, ["start", "stop"], "releaseFirst \(releaseFirst)")
            let ran = await r.h.executor.callCount()
            XCTAssertEqual(ran, 1, "releaseFirst \(releaseFirst)")
            XCTAssertEqual(count(r, { $0 == .working }), 1)
        }
    }

    func test_staleCapFromAnEarlierGeneration_isIgnored() async {
        let sleeper = ManualSleeper()
        let r = await rig([.text("open Slack"), .text("open Mail")], sleeper: sleeper)
        await r.h.hotkey.pressCommand()
        await waitUntil("cap 1") { sleeper.count == 1 }
        await r.h.hotkey.releaseCommand()
        await settle(r.h)
        await r.h.hotkey.pressCommand() // generation 2 is recording
        await waitUntil("cap 2") { sleeper.count == 2 }
        sleeper.fire(0) // generation 1's timer finally fires
        try? await Task.sleep(for: .milliseconds(30))
        var calls = await r.h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "start"], "the stale cap does not stop the newer recording")
        sleeper.fire(1)
        await waitUntil("generation 2 stopped") { await r.h.audio.calls.filter { $0 == "stop" }.count == 2 }
        await settle(r.h)
        calls = await r.h.audio.calls
        XCTAssertEqual(calls, ["start", "stop", "start", "stop"])
    }

    func test_dictationKeyKeepsItsOwn60sCap() async {
        let r = await rig([.text("hello world")])
        await r.h.hotkey.press()
        await waitUntil("recording") { await r.h.audio.calls.contains("start") }
        XCTAssertEqual(r.h.clock.pendingSleeps, 0, "no command timer for a dictation press")
        r.h.clock.advance(.seconds(61))
        try? await Task.sleep(for: .milliseconds(30))
        let calls = await r.h.audio.calls
        XCTAssertEqual(calls, ["start"], "the command cap does not apply to the dictation key")
        await r.h.hotkey.release()
        await settle(r.h)
    }

    func test_dictationCapUnchanged_withTheSessionsOwnDuration() async {
        let h = makeHarness(maxRecordingDuration: .milliseconds(40), commandInputs: Self.allOn)
        await h.session.start()
        await h.hotkey.press()
        await waitUntil("auto stop") { await h.audio.calls.contains("stop") }
        await h.hotkey.release()
        await settle(h)
        let typed = await h.ax.injectedText()
        XCTAssertEqual(typed, "hello world")
    }
}

/// A sleeper the test fires by hand and that ignores cancellation, like a timer that was already
/// past its cancel check when the generation moved on.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var count: Int { lock.withLock { waiters.count } }
    @Sendable func sleep(_ d: Duration) async {
        await withCheckedContinuation { c in lock.withLock { waiters.append(c) } }
    }
    func fire(_ i: Int) { lock.withLock { waiters[i] }.resume() }
}
