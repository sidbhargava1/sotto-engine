// The orchestrator (PLAN §4). Recording is decoupled from processing so utterance B can record
// while A is still injecting (DS-02); `injectionLock` keeps their text from interleaving.
import Foundation
import os

public actor DictationSession {
    private let log: Logger

    private let hotkey: any HotkeyMonitoring
    private let audio: any AudioCapturing
    private let transcriber: any Transcribing
    private let cleanup: any CleanupBackend
    private let rawBackend = RawBackend()
    private let injectors: InjectorChain
    private let injectionPolicy: any InjectionPolicy
    private let contextProvider: any TargetContextProviding
    private let dictionaryStore: any DictionaryStore
    private let settingsStore: any SettingsStore
    private let clipboard: any ClipboardWriting
    private let undo: any UndoPerforming
    private let history: any HistoryRecording
    private let cleanupLabel: String
    private let wallClock: @Sendable () -> Date
    private let coalescerConfig: CoalescerConfig
    private let maxRecordingDuration: Duration
    private let idleSleepGrace: Duration
    private let now: @Sendable () -> ContinuousClock.Instant  // injectable for the DS-16 window
    private let onTiming: @Sendable (UtteranceTiming) -> Void
    private let livePartials: Bool
    /// False for hosts with no "last dictation" to undo (the `sotto` CLI): every transcript is text.
    private let voiceCommands: Bool
    /// Asked once per press, after capture starts: false means nothing is displayed beyond the
    /// capsule (Classic theme, or the mascot suppressed), so no partials and no raw snapshot.
    private let displayGate: @Sendable () async -> Bool
    private let pressProbeDeadline: Duration
    private let sleep: Deadline.Sleeper  // injectable so the press-probe deadline is testable
    private let injectionLock = AsyncLock()
    private let fieldAccess: (any FieldAccessing)?

    private var isRecording = false
    private var recordingSettings = Settings()
    private var recordingGeneration = 0
    private var pressedAt: (instant: ContinuousClock.Instant, wall: Date)?
    private var pressApp: Task<String?, Never>?  // the target's app, read at hotkey-down
    private var runTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<SessionState>.Continuation] = [:]
    private var partialContinuations: [UUID: AsyncStream<PartialTranscript?>.Continuation] = [:]
    private var rawContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var recordingDisplays = true
    private var partialsTask: Task<Void, Never>?
    private var utteranceEngine: (any Transcribing)?
    private var activeUtterances = 0
    private var inFlightEvents = 0
    private var handledEvents = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastInjection: LastInjection?
    private var lastLandingState: LastLanding?
    private var lastScratch: LastScratch?
    private var landingEpoch = 0  // bumped by a host clear, so a landing in flight can't store afterwards
    private var allowUnprovableReplace = false
    private var recordingMode = PressMode.normal
    private var replaceContinuations: [UUID: AsyncStream<ReplaceOutcome>.Continuation] = [:]
    private var idleSleepTask: Task<Void, Never>?
    private var audioAsleep = false
    private var sleeping: Task<Void, Never>?  // a press waits for it, so wake never precedes sleep

    private enum PressMode { case normal, replaceLast }

    private struct LastInjection {
        let bundleID: String?
        let elementToken: AXElementToken?
        let isTerminalClass: Bool
        let at: ContinuousClock.Instant
        var recordID: UUID?  // set only when this injection's row was queued
    }

    public init(
        hotkey: any HotkeyMonitoring,
        audio: any AudioCapturing,
        transcriber: any Transcribing,
        cleanup: any CleanupBackend,
        injectors: InjectorChain,
        injectionPolicy: any InjectionPolicy = DefaultInjectionPolicy(),
        contextProvider: any TargetContextProviding,
        dictionaryStore: any DictionaryStore,
        settingsStore: any SettingsStore,
        clipboard: any ClipboardWriting,
        undo: any UndoPerforming,
        history: any HistoryRecording = NoHistory(),
        cleanupLabel: String = "llama:qwen3-4b",
        coalescerConfig: CoalescerConfig = .init(delivery: .whole),
        maxRecordingDuration: Duration = .seconds(60),
        idleSleepGrace: Duration = AudioIdleSleep.grace,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        wallClock: @escaping @Sendable () -> Date = { Date() },
        pressProbeDeadline: Duration = .milliseconds(50),
        sleep: @escaping Deadline.Sleeper = Deadline.realSleep,
        onTiming: @escaping @Sendable (UtteranceTiming) -> Void = { _ in },
        livePartials: Bool = true,
        displayGate: @escaping @Sendable () async -> Bool = { true },
        logSubsystem: LogSubsystem = .engine,
        voiceCommands: Bool = true,
        fieldAccess: (any FieldAccessing)? = nil
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.transcriber = transcriber
        self.cleanup = cleanup
        self.injectors = injectors
        self.injectionPolicy = injectionPolicy
        self.contextProvider = contextProvider
        self.dictionaryStore = dictionaryStore
        self.settingsStore = settingsStore
        self.clipboard = clipboard
        self.undo = undo
        self.history = history
        self.cleanupLabel = cleanupLabel
        self.wallClock = wallClock
        self.coalescerConfig = coalescerConfig
        self.maxRecordingDuration = maxRecordingDuration
        self.idleSleepGrace = idleSleepGrace
        self.now = now
        self.onTiming = onTiming
        self.livePartials = livePartials
        self.displayGate = displayGate
        self.pressProbeDeadline = pressProbeDeadline
        self.sleep = sleep
        self.log = logSubsystem.logger("session")
        self.voiceCommands = voiceCommands
        self.fieldAccess = fieldAccess
    }

    // MARK: Replace last

    /// The engine's memory of its last landing (read-only): nil before any landing, after a secure
    /// field or excluded app, and after a host clear. Holds dictated text; never log it.
    public var lastLanding: LastLanding? { lastLandingState }

    /// Whether a replace may use undo-then-paste where the field can't be read back (Slack and other
    /// Electron apps). Off by default; the host owns the decision. Read at landing.
    public func setAllowUnprovableReplace(_ allowed: Bool) { allowUnprovableReplace = allowed }

    /// Forget the last landing: call on screen lock, system sleep and quit. A landing that was in
    /// flight when this ran is not stored either.
    public func clearLastLanding(because reason: LastLandingClearReason) {
        landingEpoch += 1
        lastLandingState = nil
        lastScratch = nil
        log.info("last landing: cleared (\(reason.rawValue, privacy: .public))")
    }

    /// One value per replace-mode utterance that reached delivery, just before `.idle`. An empty or
    /// failed recognition emits `.error` instead and touches nothing.
    public func replaceOutcomes() -> AsyncStream<ReplaceOutcome> {
        let id = UUID()
        return AsyncStream { continuation in
            replaceContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeReplaceContinuation(id) }
            }
        }
    }

    private func removeReplaceContinuation(_ id: UUID) {
        replaceContinuations[id] = nil
    }

    private func emitReplace(_ outcome: ReplaceOutcome) {
        log.info("replace: outcome=\(String(describing: outcome), privacy: .public)")
        for continuation in replaceContinuations.values { continuation.yield(outcome) }
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task {
            for await event in hotkey.events() {
                inFlightEvents += 1
                await handle(event)
                inFlightEvents -= 1
                handledEvents += 1
                wakeDrainWaitersIfQuiescent()
            }
        }
    }

    public func stopMonitoring() {
        runTask?.cancel()
        runTask = nil
    }

    public func stateUpdates() -> AsyncStream<SessionState> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Display-only partials for the bubble: snapshots while recording, nil when they stop (release,
    /// error, 14 s ceiling) so the bubble hides until the transcript. Never reaches commands,
    /// cleanup or the log (spikes/stream/RESULTS.md).
    public func partialUpdates() -> AsyncStream<PartialTranscript?> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            partialContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removePartialContinuation(id) }
            }
        }
    }

    /// The raw transcript once STT lands, for the bubble to hold through Cleaning (mascot-concept
    /// §2 "After release"). Display-only, like partials; only for utterances the gate displayed.
    public func rawTranscriptUpdates() -> AsyncStream<String> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            rawContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRawContinuation(id) }
            }
        }
    }

    private func removeRawContinuation(_ id: UUID) {
        rawContinuations[id] = nil
    }

    private func removePartialContinuation(_ id: UUID) {
        partialContinuations[id] = nil
    }

    private func emitPartial(_ partial: PartialTranscript?) {
        for continuation in partialContinuations.values { continuation.yield(partial) }
    }

    /// Test hook (`@_spi(Testing)`, so SottoCoreTestSupport builds in release): waits until `handled` hotkey events have been taken off the stream
    /// and every utterance has finished. Counting, not yielding, is what makes this deterministic.
    @_spi(Testing) public func drain(handled target: Int) async {
        while handledEvents < target { try? await Task.sleep(for: .milliseconds(1)) }
        while inFlightEvents > 0 || activeUtterances > 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    private func wakeDrainWaitersIfQuiescent() {
        guard inFlightEvents == 0, activeUtterances == 0 else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func removeContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func emit(_ state: SessionState) {
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func handle(_ event: HotkeyEvent) async {
        switch event {
        case .pressed: // Pause means "mic off until the next press" (ui-spec §2), so a press unpauses
            await handlePressed(await unpausedSettings(), mode: .normal)
        case .pressedReplacingLast:
            await handlePressed(await unpausedSettings(), mode: .replaceLast)
        case .released: // not gated: pausing mid-hold must still end the recording
            await handleReleased()
        }
    }

    private func unpausedSettings() async -> Settings {
        var settings = await settingsStore.load()
        if settings.paused {
            settings.paused = false
            await settingsStore.save(settings)
        }
        return settings
    }

    private func handlePressed(_ settings: Settings, mode: PressMode) async {
        guard !isRecording else { return } // DS-09: never double-start the one warm engine
        isRecording = true
        recordingMode = mode
        recordingSettings = settings // WR-04: a mid-utterance toggle applies from the next press
        recordingGeneration += 1
        pressedAt = (now(), wallClock())
        // Not awaited here: the read runs while he speaks, so it adds nothing to press → recording.
        // Always read: it classifies the injection target, not just the History row.
        pressApp = Task { [contextProvider] in await contextProvider.pressTimeApp() }
        let engine = transcriber.engineForUtterance()
        utteranceEngine = engine
        idleSleepTask?.cancel()
        idleSleepTask = nil
        do {
            await sleeping?.value
            if audioAsleep { // cold press: no pre-roll, accepted (SPEC §5 step 2)
                try await audio.wake()
                audioAsleep = false
            }
            try await audio.start()
            recordingDisplays = await displayGate() // before .recording, which the UI lays out by
            emit(.recording)
            if livePartials, recordingDisplays { startPartials(engine, generation: recordingGeneration) }
            scheduleMaxDurationCap(generation: recordingGeneration)
        } catch {
            isRecording = false
            utteranceEngine = nil
            // Only a non-AudioCaptureError reads as access being off (a dead engine isn't).
            emit(.error(error is AudioCaptureError ? .micLost : .micDenied))
            emit(.idle)
        }
    }

    /// Starts at the capture mark; `handleReleased` cancels it before anything else so the final
    /// pass never queues behind a partial on the ANE (RESULTS.md "Frame budget").
    private func startPartials(_ engine: any Transcribing, generation: Int) {
        let stream = engine.partials(audio.chunks())
        partialsTask = Task {
            var failed = false
            do {
                for try await partial in stream { publishPartial(partial, generation: generation) }
            } catch {
                failed = true
            }
            partialsEnded(generation: generation, failed: failed)
        }
    }

    private func publishPartial(_ partial: PartialTranscript, generation: Int) {
        guard isRecording, generation == recordingGeneration, !Task.isCancelled else { return }
        emitPartial(partial)
    }

    private func partialsEnded(generation: Int, failed: Bool) {
        guard isRecording, generation == recordingGeneration, !Task.isCancelled else { return }
        if failed { log.notice("partials: engine stream failed; bubble hides until the transcript") }
        partialsTask = nil
        emitPartial(nil)
    }

    private func cancelPartials() {
        guard let task = partialsTask else { return }
        task.cancel()
        partialsTask = nil
        emitPartial(nil)
    }

    private func scheduleMaxDurationCap(generation: Int) {
        Task {
            try? await Task.sleep(for: maxRecordingDuration)
            await self.forceStopIfStillRecording(generation: generation)
        }
    }

    private func forceStopIfStillRecording(generation: Int) async {
        guard isRecording, generation == recordingGeneration else { return } // DS-12
        await handleReleased()
    }

    private func handleReleased() async {
        cancelPartials() // first: before audio.stop() and the final pass (60 s cap path too)
        guard isRecording else { return }
        isRecording = false
        let engine = utteranceEngine ?? transcriber
        utteranceEngine = nil
        let settings = recordingSettings
        let mode = recordingMode
        let displays = recordingDisplays
        let releasedAt = now()
        let pressed = pressedAt ?? (releasedAt, wallClock())
        let clock = UtteranceClock(pressedAt: pressed.instant, startedAt: pressed.wall, releasedAt: releasedAt)
        let pressApp = self.pressApp
        self.pressApp = nil
        emit(.transcribing)
        activeUtterances += 1
        let buffer: AudioBuffer
        do {
            buffer = try await audio.stop()
        } catch {
            emit(.error(.micLost))
            emit(.idle)
            utteranceFinished()
            return
        }
        Task {
            await self.processUtterance(buffer, engine: engine, settings: settings, mode: mode, displays: displays, clock: clock, pressApp: pressApp)
            self.utteranceFinished()
        }
    }

    private func utteranceFinished() {
        activeUtterances -= 1
        scheduleIdleSleep()
        wakeDrainWaitersIfQuiescent()
    }

    /// Puts the audio engine to sleep after the grace for its input's transport unless a press
    /// comes first; a Bluetooth input never sleeps. Called after each utterance, and by the app
    /// once the engine is warm (launch, unpause) or its input device changes.
    public func scheduleIdleSleep() {
        guard !isRecording, activeUtterances == 0 else { return }
        idleSleepTask?.cancel()
        idleSleepTask = Task {
            let transport = await audio.inputTransport()
            guard let grace = AudioIdleSleep.grace(for: transport, standard: idleSleepGrace) else {
                log.info("idle sleep: off for \(transport.rawValue, privacy: .public) input")
                return
            }
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self.sleepIfIdle()
        }
    }

    private func sleepIfIdle() async {
        guard !isRecording, activeUtterances == 0 else { return }
        idleSleepTask = nil
        audioAsleep = true
        let task = Task { await audio.sleep() }
        sleeping = task
        await task.value
        if sleeping == task { sleeping = nil }
    }

    private func processUtterance(_ buffer: AudioBuffer, engine: any Transcribing, settings: Settings, mode: PressMode, displays: Bool, clock: UtteranceClock, pressApp: Task<String?, Never>?) async {
        // No speech: say so plainly when the input itself delivered nothing (display only).
        let noSpeech: ErrorReason = buffer.silentInput.map { .silentInput(device: $0.device) } ?? .sttFailed
        guard !buffer.isEmpty else { // DS-03: silence/noise-only
            emit(.error(noSpeech))
            emit(.idle)
            return
        }

        let rawTranscript: String
        do {
            rawTranscript = try await collectTranscript(buffer, engine: engine)
        } catch is ModelNotDownloaded {
            emit(.error(.modelMissing)) // still nothing typed; the host fetches (ADR §5)
            emit(.idle)
            return
        } catch {
            emit(.error(noSpeech)) // DS-04, FT-05: STT failure never injects anything
            emit(.idle)
            return
        }

        clock.sttDone = now()
        let normalized = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            emit(.error(noSpeech))
            emit(.idle)
            return
        }
        // A newer utterance already recording owns the bubble (DS-02).
        if displays, !isRecording { for continuation in rawContinuations.values { continuation.yield(normalized) } }

        // Usually done during speech. A hung focused app can't stall delivery (or the utterances
        // queued behind it): past the deadline it's unknown, and resolveTarget still classifies
        // terminal from the release-time owner or frontmost app.
        let probed: String?? = if let pressApp { await Deadline.value(of: pressApp, within: pressProbeDeadline, sleep: sleep) } else { .some(nil) }
        if probed == nil { log.info("press app: probe missed the \(String(describing: self.pressProbeDeadline), privacy: .public) deadline, unknown") }
        let pressAppID = probed ?? nil
        await injectionLock.runExclusive {
            await self.deliverUtterance(rawTranscript: normalized, settings: settings, mode: mode, clock: clock, pressApp: pressAppID)
        }
    }

    private func collectTranscript(_ buffer: AudioBuffer, engine: any Transcribing) async throws -> String {
        var text = ""
        for try await chunk in engine.transcribe(buffer) {
            text += chunk.text
        }
        return text
    }

    private func deliverUtterance(rawTranscript: String, settings: Settings, mode: PressMode, clock: UtteranceClock, pressApp: String?) async {
        let epoch = landingEpoch
        let command = voiceCommands ? CommandParser.parse(rawTranscript) : nil
        let words = CommandParser.wordCount(rawTranscript)
        if let command { // word count only: transcripts never reach the log
            log.info("command: matched \(String(describing: command), privacy: .public) (words=\(words, privacy: .public))")
            await handleCommand(command, pressApp: pressApp)
            emit(.idle)
            return
        }
        log.info("command: none (words=\(words, privacy: .public))")

        // G1: the AX subrole probe can cost up to 250ms, so only pay it when a record could follow.
        let wantsRecord = history.wantsRecords(settings)
        let release = await contextProvider.currentContext(probeSecure: wantsRecord)
        let (context, focusMoved) = injectionPolicy.resolveTarget(pressApp: pressApp, release: release)
        log.info("target: pressKnown=\(pressApp != nil, privacy: .public) terminal=\(context.isTerminalClass, privacy: .public) frontmostDiffers=\(context.bundleID != release.bundleID, privacy: .public) focusMoved=\(focusMoved, privacy: .public)")
        let terms = (try? await dictionaryStore.load()) ?? []
        // After command matching (CLAUDE.md), so a heard-as variant can never mask "scratch that".
        // Raw fallbacks use the rewritten text too: RawRemainder aligns against what cleanup saw.
        let transcript = DictionaryRewriter.rewrite(rawTranscript, terms: terms)
        if transcript != rawTranscript { log.info("dictionary: heard-as rewrite applied") }
        let request = CleanupRequest(rawTranscript: transcript, dictionary: terms.map(\.text), targetContext: context)
        let backend: any CleanupBackend = settings.usesModelCleanup ? cleanup : rawBackend
        let stream = Self.markingFirstToken(backend.clean(request), clock: clock, now: now)

        // Replace mode after a successful scratch in this field has nothing to remove: a normal insert.
        let replacing = mode == .replaceLast && !scratchClearedTarget(context, focusMoved: focusMoved, pressedAt: clock.pressedAt)
        if mode == .replaceLast, !replacing { log.info("replace: normal insert after scratch") }

        let delivery: Delivery
        if replacing {
            delivery = await deliverReplace(rawTranscript: transcript, context: context, focusMoved: focusMoved, stream: stream, clock: clock)
        } else if focusMoved || !context.hasEditableTarget { // DS-06: no target app, or focus moved off the press-time app before release -> clipboard
            let reason: DegradedReason = context.accessibilityGranted ? .copiedNoTarget : .copiedNoAX
            delivery = await deliverToClipboard(rawTranscript: transcript, reason: reason, stream: stream, clock: clock)
        } else if context.isTerminalClass || context.elementToken != nil {
            delivery = await deliverLive(rawTranscript: transcript, context: context, overrides: settings.injectionOverrides, stream: stream, clock: clock)
        } else { // DS-06b: an app but no focused element (browser, canvas, Finder): one paste that
            // leaves the transcript on the clipboard; never unicode-type into an unknown focus
            delivery = await deliverPasteAndKeep(rawTranscript: transcript, context: context, stream: stream, clock: clock)
        }
        emit(.idle)
        let end = now()
        onTiming(clock.report(end: end, words: rawTranscript.split(whereSeparator: \.isWhitespace).count))
        guard !delivery.noWrite else { return }
        // After landing, on every landing, History on or off: the in-memory last landing obeys the
        // same secure-field and exclusion rules. The release probe is trusted only when it ran.
        let secureNow = if wantsRecord && release.isSecureInput { true } else { await contextProvider.isSecureNow(release) }
        let excluded = history.isExcluded(context: release, pressApp: pressApp, settings: settings)
        await storeLanding(delivery, rawText: transcript, context: context, secure: secureNow, excluded: excluded, epoch: epoch)
        if wantsRecord {
            await recordIfAllowed(delivery, rawTranscript: rawTranscript, context: release, pressApp: pressApp, settings: settings, secureNow: secureNow, clock: clock, end: end)
        }
    }

    /// SPEC §15: after landing, never before. Settings are the press-time snapshot, so nothing
    /// spoken before the History answer is recorded (HI-05). The recorder's gate sees the raw
    /// release-time `context` and the press-time app, so an exclusion matching either blocks the
    /// row. A secure field never records, whatever the gate says: the release probe, then a second
    /// one so a field that turned secure during cleanup counts too (HI-24). The second runs after
    /// every landing (`secureNow`, shared with the last-landing memory) and is cheap (same element,
    /// short timeout) because it holds `injectionLock`.
    private func recordIfAllowed(_ delivery: Delivery, rawTranscript: String, context: TargetContext, pressApp: String?, settings: Settings, secureNow: Bool, clock: UtteranceClock, end: ContinuousClock.Instant) async {
        guard !context.isSecureInput,
              history.shouldRecord(context: context, pressApp: pressApp, settings: settings),
              !secureNow
        else { return }
        let t = clock.rowTimings(end: end)
        let record = DictationRecord(
            startedAt: clock.startedAt, heldMs: t.held, bundleID: pressApp,
            delivery: delivery.strategy, degraded: delivery.degraded,
            backend: settings.usesModelCleanup ? cleanupLabel : "raw",
            rawText: rawTranscript, cleanText: delivery.landedText,
            sttMs: t.stt, cleanupMs: t.cleanup, landedMs: t.landed
        )
        lastInjection?.recordID = record.id  // every delivery path sets or clears lastInjection
        lastLandingState?.recordID = record.id
        history.record(record)
    }

    /// Pass-through that timestamps the first token. Dropping the result cancels `source`, which
    /// is how a stalled decode gets stopped (LB-08).
    private static func markingFirstToken(_ source: AsyncThrowingStream<String, Error>, clock: UtteranceClock, now: @escaping @Sendable () -> ContinuousClock.Instant) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await token in source {
                        clock.markFirstToken(now())
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func deliverLive(rawTranscript: String, context: TargetContext, overrides: [String: InjectionStrategy], stream: AsyncThrowingStream<String, Error>, clock: UtteranceClock) async -> Delivery {
        emit(.cleaning)
        var typed = ""
        var written = Written(kind: DeliveryKind(injectionPolicy.strategy(for: context, overrides: overrides)))
        var unverified = false
        // Once every injector has failed (e.g. AX revoked mid-flight), the rest goes to the
        // clipboard rather than being dropped (CLAUDE.md: never silently lose speech).
        var undelivered: String?

        do {
            for try await event in StreamCoalescer.coalesce(stream, config: coalescerConfig) {
                switch event {
                case .chunk(let text):
                    guard !text.isEmpty else { continue }
                    if undelivered != nil {
                        undelivered! += text
                        continue
                    }
                    emit(.injecting)
                    let tidy = InjectionText.trimLineEnds(text)
                    let sanitized = context.isTerminalClass ? InjectionText.sanitizeForTerminal(tidy) : tidy
                    await noteStart(&written, context: context, overrides: overrides)
                    let (outcome, used) = await injectWithFallback(sanitized, to: context, overrides: overrides)
                    switch outcome {
                    case .success, .unverified: // DS-05: unverified is distinct from failed — no paste fallback, just mark it
                        typed += text
                        written.add(sanitized, via: used, outcome: outcome)
                        if outcome == .unverified { unverified = true }
                        clock.markInjected(now())
                    case .failed:
                        undelivered = text
                    }
                case .stalled: // FT-03/CO-03: no first token in 1.5s, or >1s stall
                    return await finishWithRaw(rawTranscript: rawTranscript, typed: typed, written: written, undelivered: undelivered, context: context, overrides: overrides, clock: clock)
                }
            }
        } catch CleanupError.outputCapReached { // LB-06: keep what's typed; raw would duplicate it
            if let undelivered { return await copyUndelivered(undelivered, after: written, context: context, clock: clock) }
            emit(.degraded(.cleanupTruncated))
            recordInjection(context: context)
            return written.delivery(.cleanupTruncated)
        } catch { // CO-04: keep what was injected, append the remaining raw text
            return await finishWithRaw(rawTranscript: rawTranscript, typed: typed, written: written, undelivered: undelivered, context: context, overrides: overrides, clock: clock)
        }

        if undelivered == nil, typed.allSatisfy(\.isWhitespace) { // LB-05: an empty answer is a failure
            return await finishWithRaw(rawTranscript: rawTranscript, typed: typed, written: written, undelivered: nil, context: context, overrides: overrides, clock: clock)
        }
        if let undelivered { return await copyUndelivered(undelivered, after: written, context: context, clock: clock) }
        if unverified { emit(.degraded(.injectionUnverified)) }
        recordInjection(context: context)
        return written.delivery(unverified ? .injectionUnverified : nil)
    }

    /// The text that actually reached the target, after per-target sanitising: `clean_text`.
    private struct Written {
        var text = ""
        var kind: DeliveryKind
        var writes = 0
        var allVerified = true  // every write was an AX `.success`
        var start: FieldRange?  // the caret before the first write, read only for an AX landing
        var startRead = false
        private var landedOnce = false

        init(kind: DeliveryKind) { self.kind = kind }

        mutating func add(_ chunk: String, via strategy: InjectionStrategy, outcome: InjectionOutcome) {
            text += chunk
            if !landedOnce { kind = DeliveryKind(strategy) } // the first strategy that landed
            landedOnce = true
            writes += 1
            if strategy != .axSelectedText || outcome != .success { allVerified = false }
        }

        func delivery(_ degraded: DegradedReason?) -> Delivery {
            Delivery(landedText: text, strategy: kind, degraded: degraded, writes: writes, verified: writes > 0 && allVerified, start: start)
        }
    }

    /// Reads the caret before the first write: the inserted range can't be recovered afterwards. One
    /// AX read, only when the write will go through Accessibility into a non-terminal field.
    private func noteStart(_ written: inout Written, context: TargetContext, overrides: [String: InjectionStrategy]) async {
        guard !written.startRead else { return }
        written.startRead = true
        guard let fieldAccess, !context.isTerminalClass, context.elementHandle != nil,
              injectionPolicy.strategy(for: context, overrides: overrides) == .axSelectedText,
              injectors.injector(for: .axSelectedText) != nil
        else { return }
        // A replaced selection can't be proven by a count delta, so only an empty selection counts.
        if let selection = await fieldAccess.selectedRange(context), selection.length == 0 { written.start = selection }
    }

    private func finishWithRaw(rawTranscript: String, typed: String, written: Written, undelivered: String?, context: TargetContext, overrides: [String: InjectionStrategy], clock: UtteranceClock) async -> Delivery {
        if let undelivered {
            let rest = RawRemainder.after(produced: typed + undelivered, raw: rawTranscript)
            return await copyUndelivered(undelivered + rest, after: written, context: context, clock: clock)
        }
        let remainder = RawRemainder.after(produced: typed, raw: rawTranscript)
        var written = written
        await noteStart(&written, context: context, overrides: overrides)
        if await injectRemainder(remainder, context: context, overrides: overrides, into: &written) {
            clock.markInjected(now())
            emit(.degraded(.rawTyped))
            recordInjection(context: context)
            return written.delivery(.rawTyped)
        }
        return await copyUndelivered(remainder, after: written, context: context, clock: clock)
    }

    /// Partial text in the target plus the rest on the clipboard: recorded whole, as clipboard.
    private func copyUndelivered(_ text: String, after written: Written, context: TargetContext, clock: UtteranceClock) async -> Delivery {
        await clipboard.copy(text)
        clock.markLanded(now())
        lastInjection = nil // what landed in the target is partial; don't let ⌘Z guess at it
        let reason: DegradedReason = context.accessibilityGranted ? .copiedNoTarget : .copiedNoAX
        emit(.degraded(reason))
        return Delivery(landedText: written.text + text, strategy: .clipboard, degraded: reason)
    }

    /// Collects the whole stream for one-shot delivery, repairing it with raw text on failure.
    /// `fellBack` is true when raw text had to stand in for (part of) the cleanup; `truncated` when
    /// the output cap cut it (LB-06).
    private func collect(_ stream: AsyncThrowingStream<String, Error>, rawTranscript: String) async -> (text: String, fellBack: Bool, truncated: Bool) {
        var text = ""
        var stalled = false
        do {
            events: for try await event in StreamCoalescer.coalesce(stream, config: coalescerConfig) {
                switch event {
                case .chunk(let chunk): text += chunk
                case .stalled:
                    stalled = true
                    break events
                }
            }
        } catch CleanupError.outputCapReached {
            return (text, false, true) // LB-06
        } catch {
            stalled = true
        }
        if stalled { return (text + RawRemainder.after(produced: text, raw: rawTranscript), true, false) }
        if text.allSatisfy(\.isWhitespace) { return (rawTranscript, true, false) } // LB-05
        return (InjectionText.trimLineEnds(text), false, false)
    }

    private func deliverPasteAndKeep(rawTranscript: String, context: TargetContext, stream: AsyncThrowingStream<String, Error>, clock: UtteranceClock) async -> Delivery {
        emit(.cleaning)
        let (text, _, _) = await collect(stream, rawTranscript: rawTranscript)
        lastInjection = nil // no element to guard a ⌘Z against
        let reason: DegradedReason = context.accessibilityGranted ? .copiedNoTarget : .copiedNoAX
        // A host chain without paste gets the clipboard alone, as without Accessibility.
        guard context.accessibilityGranted, let paste = injectors.injector(for: .paste) else {
            await clipboard.copy(text)
            clock.markLanded(now())
            emit(.degraded(reason))
            return Delivery(landedText: text, strategy: .clipboard, degraded: reason)
        }
        _ = await paste.append(text, to: context)
        clock.markInjected(now())
        emit(.degraded(reason))
        return Delivery(landedText: text, strategy: .paste, degraded: reason, writes: 1)
    }

    private func deliverToClipboard(rawTranscript: String, reason: DegradedReason, stream: AsyncThrowingStream<String, Error>, clock: UtteranceClock) async -> Delivery {
        lastInjection = nil // nothing typed this time, so an older injection is no longer "the last"
        emit(.cleaning)
        let (text, fellBack, _) = await collect(stream, rawTranscript: rawTranscript)
        await clipboard.copy(text)
        clock.markLanded(now())
        let degraded: DegradedReason = fellBack ? .rawTyped : reason
        emit(.degraded(degraded))
        return Delivery(landedText: text, strategy: .clipboard, degraded: degraded)
    }

    /// True if the remainder landed (or there was none).
    private func injectRemainder(_ remainder: String, context: TargetContext, overrides: [String: InjectionStrategy], into written: inout Written) async -> Bool {
        guard !remainder.isEmpty else { return true }
        let sanitized = context.isTerminalClass ? InjectionText.sanitizeForTerminal(remainder) : remainder
        let (outcome, used) = await injectWithFallback(sanitized, to: context, overrides: overrides)
        guard outcome != .failed else { return false }
        written.add(sanitized, via: used, outcome: outcome)
        return true
    }

    /// Also reports the strategy that took the text: the history `delivery` column.
    private func injectWithFallback(_ text: String, to context: TargetContext, overrides: [String: InjectionStrategy]) async -> (InjectionOutcome, InjectionStrategy) {
        let first = injectionPolicy.strategy(for: context, overrides: overrides)
        var tried = first
        for entry in injectors.attempts(startingAt: first) {
            tried = entry.strategy
            let outcome = await entry.injector.append(text, to: context)
            if outcome != .failed { return (outcome, entry.strategy) }
        }
        return (.failed, tried)  // an empty chain too: the caller copies to the clipboard
    }

    private func recordInjection(context: TargetContext) {
        lastInjection = LastInjection(bundleID: context.bundleID, elementToken: context.elementToken, isTerminalClass: context.isTerminalClass, at: now())
    }

    private func noteScratch(_ context: TargetContext) {
        lastScratch = LastScratch(bundleID: context.bundleID, elementToken: context.elementToken, at: now())
        lastLandingState?.scratched = true  // Copy Last keeps the text; replace no longer applies to it
    }

    /// True when a successful scratch in this same field, under 30s before the press, left nothing to
    /// replace: replace mode then types normally (same identity rule as scratch itself).
    private func scratchClearedTarget(_ context: TargetContext, focusMoved: Bool, pressedAt: ContinuousClock.Instant) -> Bool {
        guard let scratch = lastScratch, !focusMoved, !context.isTerminalClass,
              let bundleID = scratch.bundleID, context.bundleID == bundleID,
              let element = scratch.elementToken, context.elementToken == element
        else { return false }
        return scratch.at.duration(to: pressedAt) < ReplaceLast.window
    }

    /// Replace mode at landing, under `injectionLock`: the whole replacement is collected first (it
    /// is written once, or not at all), then the guard runs against the landing as it stands now.
    /// Any refusal leaves the old text byte-identical and puts the new text on the clipboard.
    private func deliverReplace(rawTranscript: String, context: TargetContext, focusMoved: Bool, stream: AsyncThrowingStream<String, Error>, clock: UtteranceClock) async -> Delivery {
        emit(.cleaning)
        let (text, fellBack, truncated) = await collect(stream, rawTranscript: rawTranscript)
        emit(.injecting)
        let rec = lastLandingState
        let result: ReplaceResult
        if let refusal = ReplaceLast.screen(rec, context: context, focusMoved: focusMoved, pressedAt: clock.pressedAt) {
            result = .refused(refusal)
        } else if let rec {
            let replace = ReplaceLast(fields: fieldAccess, paste: injectors.injector(for: .paste), undo: undo, allowUnprovable: allowUnprovableReplace)
            result = await replace.run(text, over: rec, context: context)
        } else {
            result = .refused(.nothingToReplace)
        }
        lastInjection = nil // scratch that after a replace would undo only half of it; refuse instead
        let degraded: DegradedReason? = truncated ? .cleanupTruncated : fellBack ? .rawTyped : nil
        switch result {
        case .replaced(let method, let fieldCount):
            clock.markInjected(now())
            if let degraded { emit(.degraded(degraded)) }
            emitReplace(.replaced(method))
            var delivery = Delivery(landedText: text, strategy: method == .paste ? .paste : .ax, degraded: degraded, writes: 1)
            if method == .axVerified, let start = rec?.insertedRange {
                delivery.verified = true
                delivery.start = FieldRange(location: start.location, length: 0)
                delivery.fieldCount = fieldCount
            }
            return delivery
        case .sameAsBefore:
            emitReplace(.sameAsBefore)
            var delivery = Delivery(landedText: text, strategy: rec?.strategy ?? .clipboard, degraded: nil)
            delivery.noWrite = true
            return delivery
        case .refused, .unconfirmed:
            await clipboard.copy(text)
            clock.markLanded(now())
            let reason: DegradedReason = context.accessibilityGranted ? .copiedNoTarget : .copiedNoAX
            emit(.degraded(fellBack ? .rawTyped : reason))
            if case .refused(let why) = result { emitReplace(.refused(why)) } else { emitReplace(.unconfirmed) }
            return Delivery(landedText: text, strategy: .clipboard, degraded: fellBack ? .rawTyped : reason)
        }
    }

    /// Remembers this landing for replace, the tap and Copy Last, unless it was in a secure field or
    /// an excluded app. Logs, for every landing, the replace path it would take (no text), so the
    /// paste-path question can be answered from real use.
    private func storeLanding(_ delivery: Delivery, rawText: String, context: TargetContext, secure: Bool, excluded: Bool, epoch: Int) async {
        lastScratch = nil // any landing supersedes a scratch
        guard epoch == landingEpoch else { return }
        guard !secure, !excluded else {
            lastLandingState = nil
            log.info("replace: would=refuse(nothingToReplace) reason=\(secure ? "secure" : "excluded", privacy: .public)")
            return
        }
        var range: FieldRange?
        var count = delivery.fieldCount
        if delivery.strategy == .ax, let start = delivery.start {
            range = FieldRange(location: start.location, length: delivery.landedText.utf16.count)
            if count == nil, delivery.verified, let fieldAccess { count = await fieldAccess.characterCount(context) }
            guard epoch == landingEpoch else { return }
        }
        let verified = delivery.strategy == .ax && delivery.verified && range != nil && count != nil
        let rec = LastLanding(
            bundleID: context.bundleID, elementToken: context.elementToken, isTerminalClass: context.isTerminalClass,
            strategy: delivery.strategy, verified: verified, insertedRange: range, fieldCount: count,
            landedText: delivery.landedText, rawText: rawText, at: now(), date: wallClock(), writes: delivery.writes
        )
        lastLandingState = rec
        log.info("replace: would=\(rec.replacePath.logName, privacy: .public) strategy=\(rec.strategy.rawValue, privacy: .public) writes=\(rec.writes, privacy: .public) verified=\(rec.verified, privacy: .public) unprovableAllowed=\(self.allowUnprovableReplace, privacy: .public)")
    }

    private func handleCommand(_ command: Command, pressApp: String?) async {
        switch command {
        case .scratchThat:
            guard let last = lastInjection else {
                emit(.error(.undoRefused))
                return
            }
            // Same identity rule as injection, so the guard compares like with like.
            let (context, focusMoved) = injectionPolicy.resolveTarget(pressApp: pressApp, release: await contextProvider.currentContext(probeSecure: false))
            guard !focusMoved, Self.sameTarget(last, context),
                  now() - last.at < .seconds(30) // DS-16: 30s window
            else {
                emit(.error(.undoRefused))
                return
            }
            lastInjection = nil // DS-14b: one ⌘Z per injection; a second would undo the user's own text
            let ok = await undo.undo(context)
            if ok { noteScratch(context) }
            if ok, let id = last.recordID { history.markScratched(id) } // HI-29: only an honoured ⌘Z
            emit(ok ? .undone : .error(.undoRefused))
        }
    }

    /// DS-15/17: bundle ID AND element must match; nil == nil never passes. Terminals refuse
    /// outright (DS-15b/c): their menus take ⌘Z (reopen tab), so nothing reaches the prompt.
    private static func sameTarget(_ last: LastInjection, _ context: TargetContext) -> Bool {
        guard !last.isTerminalClass, !context.isTerminalClass,
              let bundleID = last.bundleID, context.bundleID == bundleID,
              let element = last.elementToken
        else { return false }
        return context.elementToken == element
    }
}
