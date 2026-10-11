// The orchestrator (PLAN §4). Recording is decoupled from processing so utterance B can record
// while A is still injecting (DS-02); `injectionLock` keeps their text from interleaving.
import Foundation
import os

public actor DictationSession {
    let log: Logger

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
    // Voice commands (CommandSession.swift). All default to "off", which leaves dictation untouched.
    let commandInputsProvider: @Sendable () async -> CommandInputs
    let commandCatalogProvider: @Sendable () async -> CommandCatalog
    let commandExecutor: (any CommandExecuting)?
    let commandRewrite: @Sendable (String) async -> String
    /// Times the command-key recording cap and the confirm timeout; tests drive it with `TestClock`.
    let commandSleep: Deadline.Sleeper
    let maxCommandRecordingDuration: Duration
    /// Asked once per press, after capture starts: false means nothing is displayed beyond the
    /// capsule (Classic theme, or the mascot suppressed), so no partials and no raw snapshot.
    private let displayGate: @Sendable () async -> Bool
    private let pressProbeDeadline: Duration
    private let sleep: Deadline.Sleeper  // injectable so the press-probe deadline is testable
    let injectionLock = AsyncLock()

    var isRecording = false
    var recordingKind = TriggerKind.dictation
    var recordingInputs = CommandInputs.disabled
    var commandCapTask: Task<Void, Never>?
    var pendingConfirm: PendingConfirm?
    /// Set by the key-down that confirmed, so its release does nothing.
    var ignoreCommandRelease = false
    var commandContinuations: [UUID: AsyncStream<CommandPhase>.Continuation] = [:]
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
    var lastInjection: LastInjection?
    private var idleSleepTask: Task<Void, Never>?
    private var audioAsleep = false
    private var sleeping: Task<Void, Never>?  // a press waits for it, so wake never precedes sleep

    struct LastInjection {
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
        commandInputs: @escaping @Sendable () async -> CommandInputs = { .disabled },
        commandCatalog: @escaping @Sendable () async -> CommandCatalog = { CommandCatalog() },
        commandExecutor: (any CommandExecuting)? = nil,
        commandRewrite: (@Sendable (String) async -> String)? = nil,
        commandSleep: @escaping Deadline.Sleeper = Deadline.realSleep,
        maxCommandRecordingDuration: Duration = .seconds(15)
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
        self.commandInputsProvider = commandInputs
        self.commandCatalogProvider = commandCatalog
        self.commandExecutor = commandExecutor
        // Heard-as variants are the only alias source, so the default is the user's dictionary.
        self.commandRewrite = commandRewrite ?? { text in
            DictionaryRewriter.rewrite(text, terms: (try? await dictionaryStore.load()) ?? [])
        }
        self.commandSleep = commandSleep
        self.maxCommandRecordingDuration = maxCommandRecordingDuration
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
        decideConfirm(.cancelled) // a pending confirm is released, never left waiting
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

    func emit(_ state: SessionState) {
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func handle(_ event: HotkeyEvent) async {
        switch event {
        case .pressed: // the dictation key always dictates
            let inputs = await commandInputsProvider()
            decideConfirm(.cancelled) // a dictation press answers a pending confirm with "no"
            await handlePressed(await unpausedSettings(), kind: .dictation, inputs: inputs)
        case .released: // not gated: pausing mid-hold must still end the recording
            if recordingKind == .dictation { await handleReleased() }
        case .commandPressed:
            let inputs = await commandInputsProvider()
            guard commandExecutor != nil, inputs.commandsEnabled, inputs.commandKeyEnabled else { return }
            if pendingConfirm != nil { // key-down can't tell a tap from a hold, so it confirms
                if decideConfirm(.confirmed) { ignoreCommandRelease = true }
                return
            }
            await handlePressed(await unpausedSettings(), kind: .command, inputs: inputs)
        case .commandReleased:
            if ignoreCommandRelease {
                ignoreCommandRelease = false
                return
            }
            if recordingKind == .command { await handleReleased() }
        }
    }

    /// Pause means "mic off until the next press" (ui-spec §2), so a press unpauses.
    private func unpausedSettings() async -> Settings {
        var settings = await settingsStore.load()
        if settings.paused {
            settings.paused = false
            await settingsStore.save(settings)
        }
        return settings
    }

    private func handlePressed(_ settings: Settings, kind: TriggerKind, inputs: CommandInputs) async {
        guard !isRecording else { return } // DS-09: never double-start the one warm engine
        isRecording = true
        recordingKind = kind
        recordingInputs = inputs
        recordingSettings = settings // WR-04: a mid-utterance toggle applies from the next press
        recordingGeneration += 1
        pressedAt = (now(), wallClock())
        // Not awaited here: the read runs while he speaks, so it adds nothing to press → recording.
        // Always read: it classifies the injection target, not just the History row.
        // A command press never types, so it has no target to classify.
        pressApp = kind == .command ? nil : Task { [contextProvider] in await contextProvider.pressTimeApp() }
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
            // A command press shows nothing live: no gate, no partials, no raw snapshot.
            recordingDisplays = kind == .command ? false : await displayGate() // before .recording, which the UI lays out by
            if kind == .command { emitCommand(.listening(.command)) }
            emit(.recording)
            if livePartials, recordingDisplays { startPartials(engine, generation: recordingGeneration) }
            if kind == .command { scheduleCommandCap(generation: recordingGeneration) } else { scheduleMaxDurationCap(generation: recordingGeneration) }
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

    func forceStopIfStillRecording(generation: Int) async {
        guard isRecording, generation == recordingGeneration else { return } // DS-12
        await handleReleased()
    }

    private func handleReleased() async {
        cancelPartials() // first: before audio.stop() and the final pass (60 s cap path too)
        guard isRecording else { return }
        isRecording = false
        let kind = recordingKind
        let inputs = recordingInputs
        commandCapTask?.cancel()
        commandCapTask = nil
        if kind == .command { emitCommand(.working) }
        let engine = utteranceEngine ?? transcriber
        utteranceEngine = nil
        let settings = recordingSettings
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
            await self.processUtterance(buffer, engine: engine, settings: settings, displays: displays, clock: clock, pressApp: pressApp, kind: kind, inputs: inputs)
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

    private func processUtterance(_ buffer: AudioBuffer, engine: any Transcribing, settings: Settings, displays: Bool, clock: UtteranceClock, pressApp: Task<String?, Never>?, kind: TriggerKind, inputs: CommandInputs) async {
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
        if kind == .command {
            await runCommandKeyUtterance(normalized, inputs: inputs)
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
        let route = await injectionLock.runExclusive {
            await self.deliverUtterance(rawTranscript: normalized, settings: settings, clock: clock, pressApp: pressAppID, inputs: inputs)
        }
        // After the lock: a confirm can wait seconds for a tap, and dictations must not queue behind it.
        if let route { await runPrefixCommand(route, inputs: inputs) }
    }

    private func collectTranscript(_ buffer: AudioBuffer, engine: any Transcribing) async throws -> String {
        var text = ""
        for try await chunk in engine.transcribe(buffer) {
            text += chunk.text
        }
        return text
    }

    /// Returns a command to run once the injection lock is released, when the prefix recognised one.
    private func deliverUtterance(rawTranscript: String, settings: Settings, clock: UtteranceClock, pressApp: String?, inputs: CommandInputs) async -> CommandRoute? {
        let command = voiceCommands ? CommandParser.parse(rawTranscript) : nil
        let words = CommandParser.wordCount(rawTranscript)
        if let command { // word count only: transcripts never reach the log
            log.info("command: matched \(String(describing: command), privacy: .public) (words=\(words, privacy: .public))")
            await handleCommand(command, pressApp: pressApp)
            emit(.idle)
            return nil
        }
        if let route = await routeDictationPrefix(rawTranscript, inputs: inputs) { return route }
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

        let delivery: Delivery
        // DS-06: no target app, or focus moved off the press-time app before release -> clipboard
        if focusMoved || !context.hasEditableTarget {
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
        if wantsRecord {
            await recordIfAllowed(delivery, rawTranscript: rawTranscript, context: release, pressApp: pressApp, settings: settings, clock: clock, end: end)
        }
        return nil
    }

    /// SPEC §15: after landing, never before. Settings are the press-time snapshot, so nothing
    /// spoken before the History answer is recorded (HI-05). The recorder's gate sees the raw
    /// release-time `context` and the press-time app, so an exclusion matching either blocks the
    /// row. A secure field never records, whatever the gate says: the release probe, then a second
    /// one so a field that turned secure during cleanup counts too (HI-24). That one runs only when
    /// the rest passed, and is cheap (same element, short timeout) because it holds `injectionLock`.
    private func recordIfAllowed(_ delivery: Delivery, rawTranscript: String, context: TargetContext, pressApp: String?, settings: Settings, clock: UtteranceClock, end: ContinuousClock.Instant) async {
        guard !context.isSecureInput,
              history.shouldRecord(context: context, pressApp: pressApp, settings: settings),
              !(await contextProvider.isSecureNow(context))
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
                    let (outcome, used) = await injectWithFallback(sanitized, to: context, overrides: overrides)
                    switch outcome {
                    case .success, .unverified: // DS-05: unverified is distinct from failed — no paste fallback, just mark it
                        typed += text
                        written.add(sanitized, via: used)
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
        private var landedOnce = false

        init(kind: DeliveryKind) { self.kind = kind }

        mutating func add(_ chunk: String, via strategy: InjectionStrategy) {
            text += chunk
            if !landedOnce { kind = DeliveryKind(strategy) } // the first strategy that landed
            landedOnce = true
        }

        func delivery(_ degraded: DegradedReason?) -> Delivery {
            Delivery(landedText: text, strategy: kind, degraded: degraded)
        }
    }

    private func finishWithRaw(rawTranscript: String, typed: String, written: Written, undelivered: String?, context: TargetContext, overrides: [String: InjectionStrategy], clock: UtteranceClock) async -> Delivery {
        if let undelivered {
            let rest = RawRemainder.after(produced: typed + undelivered, raw: rawTranscript)
            return await copyUndelivered(undelivered + rest, after: written, context: context, clock: clock)
        }
        let remainder = RawRemainder.after(produced: typed, raw: rawTranscript)
        var written = written
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
    /// `fellBack` is true when raw text had to stand in for (part of) the cleanup.
    private func collect(_ stream: AsyncThrowingStream<String, Error>, rawTranscript: String) async -> (text: String, fellBack: Bool) {
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
            return (text, false) // LB-06
        } catch {
            stalled = true
        }
        if stalled { return (text + RawRemainder.after(produced: text, raw: rawTranscript), true) }
        if text.allSatisfy(\.isWhitespace) { return (rawTranscript, true) } // LB-05
        return (InjectionText.trimLineEnds(text), false)
    }

    private func deliverPasteAndKeep(rawTranscript: String, context: TargetContext, stream: AsyncThrowingStream<String, Error>, clock: UtteranceClock) async -> Delivery {
        emit(.cleaning)
        let (text, _) = await collect(stream, rawTranscript: rawTranscript)
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
        return Delivery(landedText: text, strategy: .paste, degraded: reason)
    }

    private func deliverToClipboard(rawTranscript: String, reason: DegradedReason, stream: AsyncThrowingStream<String, Error>, clock: UtteranceClock) async -> Delivery {
        lastInjection = nil // nothing typed this time, so an older injection is no longer "the last"
        emit(.cleaning)
        let (text, fellBack) = await collect(stream, rawTranscript: rawTranscript)
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
        written.add(sanitized, via: used)
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
