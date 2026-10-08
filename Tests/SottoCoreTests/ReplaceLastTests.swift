// Replace-last: the landing record, the guard, the AX sequence and the refusal matrix. Fakes only.
import XCTest
@testable @_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

final class OutcomeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ReplaceOutcome] = []
    func append(_ o: ReplaceOutcome) { lock.withLock { items.append(o) } }
    var all: [ReplaceOutcome] { lock.withLock { items } }
}

final class ReplaceLastTests: SessionTestCase {
    let app = "com.test.editor"

    func fieldContext(token: Int = 1, bundle: String? = nil, terminal: Bool = false, secure: Bool = false) -> TargetContext {
        TargetContext(bundleID: bundle ?? app, isTerminalClass: terminal, elementToken: AXElementToken(token), accessibilityGranted: true,
                      isSecureInput: secure, elementHandle: AXElementHandle(NSObject()))
    }

    /// One token per request, so a landing is one write.
    struct EchoBackend: CleanupBackend {
        func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield(request.rawTranscript); $0.finish() }
        }
    }

    struct Rig {
        let h: Harness
        let field: FakeField
        let provider: FakeContextProvider
        let clock: TestClock
        let outcomes: OutcomeLog
    }

    func rig(_ transcripts: [String], field: FakeField = FakeField(), context: TargetContext? = nil, backend: any CleanupBackend = EchoBackend(),
             settings: Settings = Settings(), history: any HistoryRecording = NoHistory(), allowPaste: Bool = false,
             events: EventLog<String>? = nil, injector: ((FakeField) -> any TextInjecting)? = nil) async -> Rig {
        let clock = TestClock()
        let provider = FakeContextProvider(context ?? fieldContext())
        let h = makeHarness(
            transcriber: FixtureTranscriber(transcripts.map { .text($0) }), backend: backend, context: provider,
            coalescerConfig: CoalescerConfig(delivery: .whole, flushInterval: .milliseconds(20), firstTokenTimeout: .seconds(5), stallTimeout: .seconds(5)),
            clock: clock, settings: settings, history: history,
            chain: { _, paste, unicode in
                InjectorChain([(.axSelectedText, injector?(field) ?? FieldInjector(field, events: events)), (.paste, paste), (.unicodeType, unicode)])
            },
            fields: field, events: events
        )
        await h.session.setAllowUnprovableReplace(allowPaste)
        let log = OutcomeLog()
        let stream = await h.session.replaceOutcomes()
        Task { for await o in stream { log.append(o) } }
        return Rig(h: h, field: field, provider: provider, clock: clock, outcomes: log)
    }

    func speak(_ r: Rig) async {
        await r.h.session.start()
        await r.h.hotkey.press(); await r.h.hotkey.release()
        await settle(r.h)
    }

    func replace(_ r: Rig) async {
        await r.h.session.start()
        await r.h.hotkey.pressReplacingLast(); await r.h.hotkey.release()
        await settle(r.h)
    }

    func outcome(_ r: Rig, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async -> ReplaceOutcome? {
        await waitUntil("replace outcome", file: file, line: line) { r.outcomes.all.count >= count }
        return r.outcomes.all.last
    }

    /// Lands "send to mario", runs `mutate`, replaces with "send to maria", and checks the old text is
    /// untouched and the new text is on the clipboard.
    func assertRefused(_ reason: ReplaceRefusal, mutate: (Rig) async -> Void, rigSetup: Rig? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        let r = await rig(["send to mario", "send to maria"])
        await speak(r)
        await mutate(r)
        let before = await r.field.string
        let selection = await r.field.selection
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(reason), file: file, line: line)
        let after = await r.field.string
        XCTAssertEqual(after, before, "old text byte-identical", file: file, line: line)
        let sel = await r.field.selection
        XCTAssertEqual(sel, selection, "caret where it was", file: file, line: line)
        let clip = await r.h.clipboard.copied
        XCTAssertEqual(clip, ["send to maria"], file: file, line: line)
    }

    // MARK: record

    func test_landingRecordsRangeReadBeforeTheWrite() async {
        let r = await rig(["send to mario"], field: FakeField("Hi  END", caret: 3))
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertEqual(rec?.strategy, .ax)
        XCTAssertEqual(rec?.verified, true)
        XCTAssertEqual(rec?.insertedRange, FieldRange(location: 3, length: 13))
        XCTAssertEqual(rec?.fieldCount, 20)
        XCTAssertEqual(rec?.landedText, "send to mario")
        XCTAssertEqual(rec?.rawText, "send to mario")
        XCTAssertEqual(rec?.writes, 1)
        XCTAssertEqual(rec?.replacePath, .axVerified)
        let ops = await r.field.ops
        XCTAssertLessThan(ops.firstIndex(of: "selectedRange")!, ops.firstIndex(of: "write")!)
    }

    func test_rawTextIsAfterDictionaryRewrite() async {
        let h = makeHarness(transcriber: FixtureTranscriber([.text("ping cofi")]), dictionary: [DictionaryTerm("Kofi (cofi)")])
        await runUtterance(h)
        let rec = await h.session.lastLanding
        XCTAssertEqual(rec?.rawText, "ping Kofi")
    }

    func test_streamedMultiWriteAXLandingIsStillVerifiedAcrossTheWholeRange() async {
        let field = FakeField()
        let h = makeHarness(transcriber: FixtureTranscriber([.text("send to mario")]), backend: RawBackend(), context: FakeContextProvider(fieldContext()),
                            coalescerConfig: CoalescerConfig(delivery: .streamed, flushInterval: .milliseconds(1), firstTokenTimeout: .seconds(5), stallTimeout: .seconds(5)),
                            chain: { _, paste, unicode in InjectorChain([(.axSelectedText, FieldInjector(field)), (.paste, paste), (.unicodeType, unicode)]) },
                            fields: field)
        await runUtterance(h)
        let rec = await h.session.lastLanding
        XCTAssertEqual(rec?.insertedRange, FieldRange(location: 0, length: 13))
        XCTAssertEqual(rec?.verified, true)
    }

    // MARK: AX replace

    func test_axReplaceSwapsOnlyTheOldRange() async {
        let r = await rig(["send to mario", "send to maria", "send to marie"], field: FakeField("Hi  END", caret: 3))
        await speak(r)
        await replace(r)
        let first = await outcome(r)
        XCTAssertEqual(first, .replaced(.axVerified))
        var text = await r.field.string
        XCTAssertEqual(text, "Hi send to maria END")
        let sel = await r.field.selection
        XCTAssertEqual(sel, FieldRange(location: 16, length: 0), "caret restored after the new text")
        let rec = await r.h.session.lastLanding
        XCTAssertEqual(rec?.verified, true)
        XCTAssertEqual(rec?.insertedRange, FieldRange(location: 3, length: 13))
        XCTAssertEqual(rec?.fieldCount, 20)
        XCTAssertEqual(rec?.rawText, "send to maria")
        let clip = await r.h.clipboard.copied
        XCTAssertTrue(clip.isEmpty)
        // Chain: replacing the replacement works.
        await replace(r)
        _ = await outcome(r, count: 2)
        text = await r.field.string
        XCTAssertEqual(text, "Hi send to marie END")
    }

    func test_replaceDoesNotRunUnderTheScratchUndo() async {
        let r = await rig(["send to mario", "send to maria"])
        await speak(r)
        await replace(r)
        _ = await outcome(r)
        let calls = await r.h.undo.callCount()
        XCTAssertEqual(calls, 0, "AX replace never presses undo")
    }

    func test_sameAsBeforeWritesNothing() async {
        let r = await rig(["send to mario", "send to mario "])
        await speak(r)
        await r.field.clearOps()
        let before = await r.h.session.lastLanding
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .sameAsBefore)
        let ops = await r.field.ops
        XCTAssertFalse(ops.contains("write") || ops.contains("replaceSelection") || ops.contains("setSelectedRange"), "\(ops)")
        let clip = await r.h.clipboard.copied
        XCTAssertTrue(clip.isEmpty)
        let after = await r.h.session.lastLanding
        XCTAssertEqual(after, before, "the record is untouched")
    }

    // MARK: refusal matrix

    func test_refuse_nothingToReplace_none() async {
        let r = await rig(["send to maria"])
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.nothingToReplace))
        let text = await r.field.string
        XCTAssertEqual(text, "")
        let clip = await r.h.clipboard.copied
        XCTAssertEqual(clip, ["send to maria"])
    }

    func test_refuse_nothingToReplace_afterSecureLanding() async {
        let r = await rig(["send to mario", "send to maria"], context: fieldContext(secure: true))
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertNil(rec, "secure field is never remembered, History off")
        await r.provider.set(fieldContext())
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.nothingToReplace))
        let text = await r.field.string
        XCTAssertEqual(text, "send to mario")
    }

    func test_refuse_nothingToReplace_afterClipboardLanding() async {
        let r = await rig(["send to mario", "send to maria"], context: makeTestContext(bundleID: nil, hasTarget: false))
        await speak(r)
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.nothingToReplace))
    }

    func test_refuse_differentField() async {
        await assertRefused(.differentField) { r in await r.provider.set(self.fieldContext(token: 2)) }
    }

    func test_refuse_differentApp() async {
        await assertRefused(.differentField) { r in await r.provider.set(self.fieldContext(bundle: "com.other")) }
    }

    func test_refuse_tooLongAgo() async {
        await assertRefused(.tooLongAgo) { r in r.clock.advance(.seconds(31)) }
    }

    func test_29SecondsStillReplaces() async {
        let r = await rig(["send to mario", "send to maria"])
        await speak(r)
        r.clock.advance(.seconds(29))
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .replaced(.axVerified))
    }

    func test_refuse_terminalNow() async {
        await assertRefused(.terminal) { r in await r.provider.set(self.fieldContext(terminal: true)) }
    }

    func test_refuse_terminalLanding() async {
        let term = fieldContext(terminal: true)
        let r = await rig(["ls", "pwd"], context: term)
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertEqual(rec?.strategy, .unicode)
        XCTAssertEqual(rec?.replacePath, .refuse(.terminal))
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.terminal))
        let clip = await r.h.clipboard.copied
        XCTAssertEqual(clip, ["pwd"])
    }

    func test_refuse_textChanged_userTypedAfter() async {
        await assertRefused(.textChanged) { r in await r.field.userTypes(" now") }
    }

    func test_refuse_textChanged_caretMoved() async {
        await assertRefused(.textChanged) { r in await r.field.userMovesCaret(to: 4) }
    }

    func test_refuse_textChanged_sameLengthEdit() async {
        await assertRefused(.textChanged) { r in await r.field.userEdits(at: 12, to: "x") }
    }

    func test_refuse_cantCheck_countUnreadable() async {
        await assertRefused(.cantCheckField) { r in await r.field.setFaults([.countUnreadable]) }
    }

    func test_refuse_cantCheck_selectionUnreadable() async {
        await assertRefused(.cantCheckField) { r in await r.field.setFaults([.selectionUnreadable]) }
    }

    func test_refuse_cantCheck_textUnreadableEverywhere() async {
        await assertRefused(.cantCheckField) { r in await r.field.setFaults([.stringForRangeUnreadable, .valueUnreadable]) }
    }

    func test_valueSubstringFallbackStillReplaces() async {
        let r = await rig(["send to mario", "send to maria"])
        await speak(r)
        await r.field.setFaults([.stringForRangeUnreadable])
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .replaced(.axVerified))
    }

    func test_refuse_cantCheck_typedTextOverride() async {
        var settings = Settings()
        settings.injectionOverrides[app] = .unicodeType
        let r = await rig(["send to mario", "send to maria"], settings: settings)
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertEqual(rec?.replacePath, .refuse(.cantCheckField))
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.cantCheckField))
        let undo = await r.h.undo.callCount()
        XCTAssertEqual(undo, 0)
    }

    // MARK: partial failures leave the old text intact

    func test_partial_setRangeFails() async {
        await assertRefused(.cantCheckField) { r in await r.field.setFaults([.setRangeFails]) }
    }

    func test_partial_setRangeIgnored() async {
        await assertRefused(.cantCheckField) { r in await r.field.setFaults([.setRangeIgnored]) }
    }

    func test_partial_writeRefused() async {
        await assertRefused(.cantCheckField) { r in await r.field.setFaults([.replaceFails]) }
    }

    func test_partial_writeAcceptedButNothingWritten_isUnconfirmedAndTextIntact() async {
        let r = await rig(["send to mario", "send to maria"])
        await speak(r)
        await r.field.setFaults([.replaceIgnored])
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .unconfirmed)
        let text = await r.field.string
        XCTAssertEqual(text, "send to mario")
        let clip = await r.h.clipboard.copied
        XCTAssertEqual(clip, ["send to maria"])
    }

    func test_partial_writeRejectedButAppliedLater_isUnconfirmed() async {
        let r = await rig(["send to mario", "send to maria"])  // same length: a count check can't tell
        await speak(r)
        await r.field.setFaults([.replaceRejectedAppliesLate])
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .unconfirmed)
        let clip = await r.h.clipboard.copied
        XCTAssertEqual(clip, ["send to maria"])
    }

    func test_partial_writeRejectedButAppliedAtOnce_sameLength_isUnconfirmed() async {
        let r = await rig(["send to mario", "send to maria"])
        await speak(r)
        await r.field.setFaults([.replaceRejectedButApplied])
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .unconfirmed)
    }

    func test_partial_caretRestoreFails_isUnconfirmed() async {
        // The range select works, the write is refused, and the caret can't be put back: the old text
        // would stay selected, so this must not read as a clean refusal.
        let r = await rig(["send to mario", "send to maria"])
        await speak(r)
        await r.field.setFaults([.replaceFails, .caretRestoreFails])
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .unconfirmed)
    }

    func test_clearDuringTheSteps_stopsTheWrite() async {
        let r = await rig(["send to mario"])
        await speak(r)
        let rec = await r.h.session.lastLanding!
        let replace = ReplaceLast(fields: r.field, paste: nil, undo: FakeUndo(), allowUnprovable: false, abort: { true })
        let result = await replace.run("send to maria", over: rec, context: fieldContext())
        XCTAssertEqual(result, .refused(.nothingToReplace))
        let text = await r.field.string
        let sel = await r.field.selection
        XCTAssertEqual(text, "send to mario")
        XCTAssertEqual(sel, FieldRange(location: 13, length: 0))
    }

    // MARK: identity edge cases

    func test_nilElementTokenNeverMatches() {
        let rec = LastLanding(bundleID: "a", elementToken: nil, isTerminalClass: false, strategy: .paste, verified: false, insertedRange: nil,
                              fieldCount: nil, landedText: "x", rawText: "x", at: .now, date: Date(), writes: 1)
        let nilCtx = TargetContext(bundleID: "a", isTerminalClass: false, elementToken: nil, accessibilityGranted: true)
        XCTAssertEqual(ReplaceLast.screen(rec, context: nilCtx, focusMoved: false, pressedAt: .now), .differentField)
        let withEl = TargetContext(bundleID: "a", isTerminalClass: false, elementToken: AXElementToken(1), accessibilityGranted: true)
        XCTAssertEqual(ReplaceLast.screen(rec, context: withEl, focusMoved: false, pressedAt: .now), .differentField)
    }

    func test_nilBundleNeverMatches() {
        let rec = LastLanding(bundleID: nil, elementToken: AXElementToken(1), isTerminalClass: false, strategy: .ax, verified: true,
                              insertedRange: FieldRange(location: 0, length: 1), fieldCount: 1, landedText: "x", rawText: "x", at: .now, date: Date(), writes: 1)
        let ctx = TargetContext(bundleID: nil, isTerminalClass: false, elementToken: AXElementToken(1), accessibilityGranted: true)
        XCTAssertEqual(ReplaceLast.screen(rec, context: ctx, focusMoved: false, pressedAt: .now), .differentField)
    }

    func test_focusMovedRefusesInTheGuard() {
        let rec = LastLanding(bundleID: "a", elementToken: AXElementToken(1), isTerminalClass: false, strategy: .ax, verified: true,
                              insertedRange: FieldRange(location: 0, length: 1), fieldCount: 1, landedText: "x", rawText: "x", at: .now, date: Date(), writes: 1)
        let ctx = TargetContext(bundleID: "a", isTerminalClass: false, elementToken: AXElementToken(1), accessibilityGranted: true)
        XCTAssertNil(ReplaceLast.screen(rec, context: ctx, focusMoved: false, pressedAt: .now))
        XCTAssertEqual(ReplaceLast.screen(rec, context: ctx, focusMoved: true, pressedAt: .now), .differentField)
    }

    func test_refuse_focusMovedInSession() async {
        await assertRefused(.differentField) { r in
            // Same bundle and element, but the focus owner is another app: resolveTarget reports a move.
            await r.provider.set(TargetContext(bundleID: self.app, isTerminalClass: false, elementToken: AXElementToken(1), accessibilityGranted: true,
                                               elementHandle: AXElementHandle(NSObject()), focusOwnerBundleID: "com.other"))
        }
    }

    // MARK: empty recognition

    func test_emptySpeechLeavesOldTextAndEmitsNoOutcome() async {
        let r = await rig(["send to mario", ""])
        let states = await collectStates(r.h)
        await speak(r)
        await replace(r)
        let settled = await states.settled()
        XCTAssertTrue(settled.contains(.error(.sttFailed)))
        let text = await r.field.string
        XCTAssertEqual(text, "send to mario")
        XCTAssertTrue(r.outcomes.all.isEmpty)
        let clip = await r.h.clipboard.copied
        XCTAssertTrue(clip.isEmpty)
    }

    // MARK: paste path

    func pasteRig(allow: Bool, transcripts: [String] = ["send to mario", "send to maria"], backend: any CleanupBackend = EchoBackend()) async -> (Rig, EventLog<String>) {
        var settings = Settings()
        settings.injectionOverrides[app] = .paste
        let events = EventLog<String>()
        let r = await rig(transcripts, backend: backend, settings: settings, allowPaste: allow, events: events)
        return (r, events)
    }

    func test_pasteReplace_onlyWithFlagAndOneWrite_undoThenPaste() async {
        let (r, events) = await pasteRig(allow: true)
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertEqual(rec?.replacePath, .paste)
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .replaced(.paste))
        XCTAssertEqual(events.all, ["paste.append", "undo", "paste.append"])
        let pasted = await r.h.paste.injectedText()
        XCTAssertEqual(pasted, "send to mariosend to maria", "the landing, then the replacement")
    }

    func test_pasteReplace_refusedWithoutFlag() async {
        let (r, events) = await pasteRig(allow: false)
        await speak(r)
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.cantCheckField))
        XCTAssertEqual(events.all, ["paste.append"], "no undo, no second paste")
        let clip = await r.h.clipboard.copied
        XCTAssertEqual(clip, ["send to maria"])
    }

    func test_pasteReplace_refusedAfterTwoWrites() async {
        // Cleanup dies after the first word, so the raw remainder is a second paste write.
        let backend = FixtureBackend(steps: [.init("Send ")], ending: .fail(FakeError(label: "x")))
        let (r, events) = await pasteRig(allow: true, transcripts: ["send to mario", "send to maria"], backend: backend)
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertEqual(rec?.writes, 2)
        XCTAssertEqual(rec?.replacePath, .refuse(.cantCheckField))
        events.append("--")
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.cantCheckField))
        XCTAssertFalse(events.all.suffix(from: events.all.firstIndex(of: "--")!).contains("undo"))
    }

    func test_pasteReplace_stillGuardedByWindow() async {
        let (r, _) = await pasteRig(allow: true)
        await speak(r)
        r.clock.advance(.seconds(31))
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.tooLongAgo))
        let undo = await r.h.undo.callCount()
        XCTAssertEqual(undo, 0)
    }

    // MARK: in flight

    actor HeldBackend: CleanupBackend {
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var started = 0
        nonisolated func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in
                Task {
                    if await self.begin() == 1 { await self.wait() }
                    c.yield(request.rawTranscript)
                    c.finish()
                }
            }
        }
        private func begin() -> Int { started += 1; return started }
        private func wait() async { if !released { await withCheckedContinuation { gate = $0 } } }
        func release() { released = true; gate?.resume(); gate = nil }
    }

    func test_inFlightUtteranceLandsFirstThenReplaceChecksAgainstIt() async {
        let backend = HeldBackend()
        let audio = FixtureAudioCapture(buffers: [AudioBuffer(samples: [0.1]), AudioBuffer(samples: [0.2])])
        let field = FakeField()
        let provider = FakeContextProvider(fieldContext())
        let h = makeHarness(transcriber: FixtureTranscriber([.text("send to mario"), .text("send to maria")]), backend: backend, audio: audio,
                            context: provider,
                            chain: { _, paste, unicode in InjectorChain([(.axSelectedText, FieldInjector(field)), (.paste, paste), (.unicodeType, unicode)]) },
                            fields: field)
        let log = OutcomeLog()
        let stream = await h.session.replaceOutcomes()
        Task { for await o in stream { log.append(o) } }
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await waitUntil("first utterance cleaning") { await backend.started == 1 }
        await h.hotkey.pressReplacingLast(); await h.hotkey.release()
        try? await Task.sleep(for: .milliseconds(50))
        let mid = await field.string
        XCTAssertEqual(mid, "", "nothing lands while the first is held; the second waits behind it")
        await backend.release()
        await settle(h)
        await waitUntil("outcome") { log.all.count == 1 }
        XCTAssertEqual(log.all, [.replaced(.axVerified)])
        let text = await field.string
        XCTAssertEqual(text, "send to maria")
    }

    // MARK: after scratch

    func test_replaceAfterSuccessfulScratchIsANormalInsert() async {
        let r = await rig(["send to mario", "scratch that", "send to maria"])
        await speak(r)
        await speak(r) // scratch (FakeUndo does not edit the fake field; the field is the stand-in)
        let calls = await r.h.undo.callCount()
        XCTAssertEqual(calls, 1)
        await r.field.clearOps()
        await replace(r)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(r.outcomes.all.isEmpty, "no replace outcome: it typed normally")
        let ops = await r.field.ops
        XCTAssertTrue(ops.contains("write"))
        XCTAssertFalse(ops.contains("replaceSelection"))
        let clip = await r.h.clipboard.copied
        XCTAssertTrue(clip.isEmpty)
    }

    func test_replaceLongAfterScratchIsNothingToReplace() async {
        let r = await rig(["send to mario", "scratch that", "send to maria"])
        await speak(r)
        await speak(r)
        r.clock.advance(.seconds(31))
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.nothingToReplace))
    }

    func test_replaceAfterScratchInAnotherFieldIsNothingToReplace() async {
        let r = await rig(["send to mario", "scratch that", "send to maria"])
        await speak(r)
        await speak(r)
        await r.provider.set(fieldContext(token: 9))
        await replace(r)
        let result = await outcome(r)
        XCTAssertEqual(result, .refused(.nothingToReplace))
    }

    func test_scratchAfterAReplaceIsRefused() async {
        let r = await rig(["send to mario", "send to maria", "scratch that"])
        await speak(r)
        await replace(r)
        _ = await outcome(r)
        let states = await collectStates(r.h)
        await speak(r)
        let settled = await states.settled()
        XCTAssertTrue(settled.contains(.error(.undoRefused)))
        let calls = await r.h.undo.callCount()
        XCTAssertEqual(calls, 0)
    }

    // MARK: secure, excluded, clearing

    final class ExcludingHistory: HistoryRecording, @unchecked Sendable {
        func wantsRecords(_ settings: Settings) -> Bool { false }
        func shouldRecord(context: TargetContext, pressApp: String?, settings: Settings) -> Bool { false }
        func record(_ record: DictationRecord) {}
        func markScratched(_ id: UUID) {}
        func isExcluded(context: TargetContext, pressApp: String?, settings: Settings) -> Bool { true }
    }

    func test_excludedAppIsNeverRemembered_historyOff() async {
        let r = await rig(["send to mario"], history: ExcludingHistory())
        await speak(r)
        let text = await r.field.string
        XCTAssertEqual(text, "send to mario", "it still landed")
        let rec = await r.h.session.lastLanding
        XCTAssertNil(rec)
    }

    func test_secureFieldIsNeverRemembered_historyOn() async {
        let r = await rig(["send to mario"], context: fieldContext(secure: true), history: RecordingHistory())
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertNil(rec)
    }

    func test_historyOffStillRemembersAnOrdinaryLanding() async {
        let r = await rig(["send to mario"])
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertNotNil(rec)
    }

    func test_aSecureLandingSupersedesTheEarlierRecord() async {
        let r = await rig(["send to mario", "pw"])
        await speak(r)
        await r.provider.set(fieldContext(secure: true))
        await speak(r)
        let rec = await r.h.session.lastLanding
        XCTAssertNil(rec, "the last landing is the secure one, and it is not kept")
    }

    actor OrderedProvider: TargetContextProviding {
        let events: EventLog<String>
        let context: TargetContext
        init(_ context: TargetContext, events: EventLog<String>) { self.context = context; self.events = events }
        func currentContext(probeSecure: Bool) async -> TargetContext { context }
        func isSecureNow(_ context: TargetContext) async -> Bool { events.append("secureNow"); return false }
        func pressTimeApp() async -> String? { context.bundleID }
    }

    func test_secureCheckRunsAfterTheLanding() async {
        let events = EventLog<String>()
        let field = FakeField()
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello")]), context: OrderedProvider(fieldContext(), events: events),
                            chain: { _, paste, unicode in InjectorChain([(.axSelectedText, FieldInjector(field, events: events)), (.paste, paste), (.unicodeType, unicode)]) },
                            fields: field)
        await runUtterance(h)
        XCTAssertEqual(events.all, ["inject", "secureNow"])
    }

    func test_clearOnLockSleepQuit() async {
        for reason in [LastLandingClearReason.screenLocked, .systemSleep, .quit] {
            let r = await rig(["send to mario", "send to maria"])
            await speak(r)
            let had = await r.h.session.lastLanding
            XCTAssertNotNil(had)
            await r.h.session.clearLastLanding(because: reason)
            let rec = await r.h.session.lastLanding
            XCTAssertNil(rec, "\(reason)")
            await replace(r)
            let result = await outcome(r)
            XCTAssertEqual(result, .refused(.nothingToReplace))
        }
    }

    func test_clearDuringAnInFlightLandingStopsItBeingStored() async {
        let backend = HeldBackend()
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello")]), backend: backend)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await waitUntil("cleaning") { await backend.started == 1 }
        await h.session.clearLastLanding(because: .screenLocked)
        await backend.release()
        await settle(h)
        let rec = await h.session.lastLanding
        XCTAssertNil(rec)
    }

    // MARK: path table

    func test_replacePathTable() {
        func rec(_ s: DeliveryKind, verified: Bool = false, range: Bool = false, terminal: Bool = false, writes: Int = 1) -> LastLanding {
            LastLanding(bundleID: "a", elementToken: AXElementToken(1), isTerminalClass: terminal, strategy: s, verified: verified,
                        insertedRange: range ? FieldRange(location: 0, length: 1) : nil, fieldCount: range ? 1 : nil,
                        landedText: "x", rawText: "x", at: .now, date: Date(), writes: writes)
        }
        XCTAssertEqual(rec(.ax, verified: true, range: true).replacePath, .axVerified)
        XCTAssertEqual(rec(.ax, verified: false, range: true).replacePath, .refuse(.cantCheckField))
        XCTAssertEqual(rec(.paste).replacePath, .paste)
        XCTAssertEqual(rec(.paste, writes: 2).replacePath, .refuse(.cantCheckField))
        XCTAssertEqual(rec(.unicode).replacePath, .refuse(.cantCheckField))
        XCTAssertEqual(rec(.unicode, terminal: true).replacePath, .refuse(.terminal))
        XCTAssertEqual(rec(.clipboard).replacePath, .refuse(.nothingToReplace))
    }
}
