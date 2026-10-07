// Engine starts at launch and stays warm for a grace period after each dictation, then sleeps
// until the next press (SPEC §5 step 2). The tap writes native-rate mono into a 90s ring; a warm
// start() only marks an offset with 150ms pre-roll. A press on a sleeping engine pays the cold
// start, waits for the tap to carry real audio (AudioWake), and has no pre-roll. Bluetooth inputs
// never sleep (AudioIdleSleep): their wake is an HFP route switch.
import AVFoundation
import AudioToolbox
import Synchronization
import SottoCore
import os

public final class AVAudioEngineCapture: AudioCapturing, @unchecked Sendable {
    public enum Failure: Error { case micDenied, notRecording, deviceSwitch(OSStatus) }

    private static let ringSeconds: Double = 90
    private let log: Logger
    // @unchecked: `engine` is only touched from prewarm/configuration-change on the main actor;
    // all tap/start/stop state lives behind `state`.
    private let engine = AVAudioEngine()
    private let state = Mutex(Ring())

    /// `preferredInputUID`: the mic to open (nil follows the macOS default); change it later
    /// with `selectInput(uid:)`.
    public init(log: LogSubsystem, preferredInputUID: String? = nil) {
        self.log = log.logger("audio")
        selection = InputSelection(preferred: preferredInputUID)
    }
    private var configObserver: NSObjectProtocol?
    private var suspended = false  // main actor only, like `engine`
    // Main actor only, like `engine`. Settings mic picker (ui-spec §4): set at init, then only
    // through `selectInput(uid:)`.
    private var selection: InputSelection
    private var availableUIDs: [String] = []
    // Main actor only. What InputSelection needs to step around an unstable device.
    private var defaultUID: String?
    private var fallbackUIDs: [String] = []
    private var inputNames: [String: String] = [:]
    // Main actor only. Configuration-change restarts (SPEC §5 "Restart budget").
    private var budget = RestartBudget()
    private var restarting = false
    private var pendingCheck: Task<Void, Never>?
    private var lastDevice: AudioInputDevice?  // survives a failed restart, which clears `device`
    /// Fires after each start attempt and device change, for the Settings footnote.
    public var onStatusChange: (@MainActor () -> Void)?
    /// Fires after a give-up fallback lands on another device, so the app re-evaluates idle sleep.
    public var onInputSwitched: (@MainActor () -> Void)?
    private let device = Mutex<AudioInputDevice?>(nil)  // what the engine opens; read for the sleep policy
    private let levelSink = Mutex(LevelSink())
    private let chunkSink = Mutex<(id: Int, continuation: AsyncStream<SottoCore.AudioBuffer>.Continuation?)>((0, nil))
    private static let chunkInterval: Duration = .milliseconds(100)

    // RMS accumulator for `levels()`; the tap only touches it while a subscriber exists.
    private struct LevelSink {
        var continuation: AsyncStream<Float>.Continuation?
        var id = 0
        var sum: Float = 0
        var count = 0
        var published = 0
    }

    struct Ring {  // internal for SottoTests (chunk cursor across restarts)
        var buffer: [Float] = []
        var rate: Double = 0
        var written = 0  // monotonic sample count; index = written % buffer.count
        var mark: Int?
        var floor = 0  // `written` at the last suspend: older samples predate the sleep, never pre-roll
        var carried: [Float] = []  // already-16k audio from before a mid-record rate change
        var startedAt = 0  // `written` when the engine last started
        var cold = false  // set by a press's wake: start() marks from `startedAt`, not pre-roll
        var probe = AudioWake.Probe()  // tap buffers since the engine last started
        // chunks() pump state. Read by a non-realtime task, never by the tap.
        var chunksActive = false
        var chunkCursor: Int?  // `written` index read up to; nil means "from the mark"
        var chunkBacklog: [(rate: Double, samples: [Float])] = []  // unread audio from before a restart

        mutating func resetChunks(active: Bool) {
            chunksActive = active
            chunkCursor = nil
            chunkBacklog = []
        }

        /// Restart mid-record: banks the segment for stop() as 16 kHz, and hands the chunk pump its
        /// unread tail now, since `reset` may zero `written`. False if not recording.
        mutating func bankForRestart() -> Bool {
            guard let mark else { return false }
            carried += (try? AudioConversion.to16kMono(since(mark), sourceRate: rate)) ?? []
            if chunksActive {
                chunkBacklog.append((rate, since(chunkCursor ?? mark)))
                chunkCursor = nil  // resumes from the new mark
            }
            self.mark = nil
            return true
        }

        /// Everything since the pump's last read, at native rate(s), and advances the cursor.
        mutating func takeChunkDeltas() -> [(rate: Double, samples: [Float])]? {
            guard chunksActive else { return nil }
            var out = chunkBacklog
            chunkBacklog = []
            if let from = chunkCursor ?? mark {
                out.append((rate, since(from)))
                chunkCursor = written
            }
            return out
        }

        mutating func note(rms: Float) {
            probe.buffers += 1
            probe.peakRMS = max(probe.peakRMS, rms)
        }

        mutating func reset(rate: Double) {
            self.rate = rate
            buffer = [Float](repeating: 0, count: Int(rate * AVAudioEngineCapture.ringSeconds))
            written = 0
            floor = 0
        }

        mutating func append(_ samples: [Float]) {
            guard !buffer.isEmpty else { return }
            for s in samples {
                buffer[written % buffer.count] = s
                written += 1
            }
        }

        func since(_ mark: Int) -> [Float] {
            let count = min(written - mark, buffer.count)  // stuck hotkey: keep the newest 90s
            guard count > 0 else { return [] }
            let start = written - count
            return (start..<written).map { buffer[$0 % buffer.count] }
        }
    }

    @MainActor
    public func prewarm() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.micDenied }
        try startEngine()
        suspended = false
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    /// Tries the chosen device, then the system default (InputSelection). The stored choice is
    /// kept either way; the Settings footnote reads `status`.
    @MainActor
    private func startEngine() throws {
        let inputs = AudioDevices.inputs()
        noteInputs(inputs)
        var lastError: Error = AudioCaptureError.noInput
        defer { onStatusChange?() }
        // Empty only when every device was given up on: a press still tries the default.
        let attempts = selection.attempts(available: availableUIDs, defaultUID: defaultUID, fallbacks: fallbackUIDs)
        for uid in attempts.isEmpty ? [nil] : attempts {
            let id = uid.flatMap { uid in inputs.first { $0.device.uid == uid }?.id } ?? AudioDevices.defaultInputID()
            do {
                guard let id else { throw AudioCaptureError.noInput }
                try start(on: id)
                selection.started(on: uid)
                return
            } catch {
                selection.failed(on: uid)
                lastError = error
                if uid != nil { log.error("chosen input failed to start (\(String(describing: error), privacy: .public)); trying the system default") }
            }
        }
        setDevice(nil)
        throw lastError
    }

    @MainActor
    private func start(on id: AudioDeviceID) throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        try point(input, at: id)
        guard let format = Self.tapFormat(input) else {
            log.error("no input device; not starting the engine")
            throw AudioCaptureError.noInput
        }
        state.withLock { ring in
            if ring.rate != format.sampleRate { ring.reset(rate: format.sampleRate) }
            ring.startedAt = ring.written
            ring.probe = AudioWake.Probe()
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: makeTap())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        setDevice(AudioDevices.describe(id))
        log.info("audio engine running at \(format.sampleRate, privacy: .public)Hz")
    }

    /// The hardware's format, not `outputFormat`: that stays stale after a device switch (seen
    /// 48k on a 44.1k device), and a tap off the hardware rate is AVFAudio's hwFormat exception.
    /// nil with no input device: a 0 Hz tap raises an NSException Swift can't catch.
    @MainActor
    private static func tapFormat(_ input: AVAudioInputNode) -> AVAudioFormat? {
        let hw = input.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { return nil }
        if let format = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channelCount) { return format }
        // >2 channels (audio interfaces) needs an explicit layout.
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hw.channelCount) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channelLayout: layout)
    }

    /// Points the input unit at `id`. Explicit even for "System default", since a unit once
    /// pointed elsewhere no longer follows the default by itself.
    @MainActor
    private func point(_ input: AVAudioInputNode, at id: AudioDeviceID) throws {
        guard let unit = input.audioUnit else { throw AudioCaptureError.noInput }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
        guard current != id else { return }
        var id = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, size)
        guard status == noErr else { throw Failure.deviceSwitch(status) }
    }

    /// Caches the device list for InputSelection: the default's uid, and stand-ins for an
    /// unstable device, built-in first and Bluetooth last.
    @MainActor
    private func noteInputs(_ inputs: [(id: AudioDeviceID, device: AudioInputDevice)]) {
        availableUIDs = inputs.map(\.device.uid)
        let defaultID = AudioDevices.defaultInputID()
        defaultUID = inputs.first { $0.id == defaultID }?.device.uid
        let rank: [AudioTransport: Int] = [.builtIn: 0, .usb: 1, .other: 2, .bluetooth: 3]
        fallbackUIDs = inputs.filter { !AudioDevices.isVirtual($0.id) }.map(\.device)
            .enumerated()
            .sorted { (rank[$0.element.transport] ?? 2, $0.offset) < (rank[$1.element.transport] ?? 2, $1.offset) }
            .map(\.element.uid)
        inputNames = Dictionary(inputs.map { ($0.device.uid, $0.device.name) }, uniquingKeysWith: { a, _ in a })
    }

    @MainActor
    private var fellBack: Bool {
        selection.fellBack(available: availableUIDs, defaultUID: defaultUID, fallbacks: fallbackUIDs)
    }

    /// What the sleep policy and the Settings Bluetooth note read: the device recording, or
    /// while asleep the one the next start is expected to open. Logged on change.
    @MainActor
    private func setDevice(_ new: AudioInputDevice?) {
        let previous = device.withLock { d in
            defer { d = new }
            return d
        }
        if let new { lastDevice = new }
        if let new, new != previous { // device name only; nothing else identifying
            log.info("input: \(new.name, privacy: .public) transport=\(new.transport.rawValue, privacy: .public) nominal=\(new.sampleRate, privacy: .public)Hz fallback=\(self.fellBack, privacy: .public)")
        }
    }

    /// The device InputSelection expects, resolved to a description (nil uid: the system default).
    @MainActor
    private func expectedDevice(_ inputs: [(id: AudioDeviceID, device: AudioInputDevice)]) -> AudioInputDevice? {
        let attempts = selection.attempts(available: availableUIDs, defaultUID: defaultUID, fallbacks: fallbackUIDs)
        guard !attempts.isEmpty else { return nil }  // every device given up on: the mic is off
        let uid = selection.expected(available: availableUIDs, defaultUID: defaultUID, fallbacks: fallbackUIDs)
        if let uid { return inputs.first { $0.device.uid == uid }?.device }
        return AudioDevices.defaultInputID().flatMap(AudioDevices.describe)
    }

    /// The default input or the device list changed (AudioDeviceMonitor). Restarts a running
    /// engine only if that changes which device it should be on.
    @MainActor
    public func inputDevicesChanged() {
        let inputs = AudioDevices.inputs()
        let previous = Set(availableUIDs)
        noteInputs(inputs)
        // Only a real list change resets the budget: a flapping route can also fire this
        // notification, and resetting on every one would keep the budget from ever tripping.
        if Set(availableUIDs) != previous {
            budget.reset()
            selection.devicesChanged(available: availableUIDs)
        }
        let wanted = expectedDevice(inputs)
        let current = device.withLock { $0 }
        if engine.isRunning, wanted?.uid != current?.uid {
            restart("input device changed")  // publishes status itself
            return
        }
        if !engine.isRunning { setDevice(wanted) }
        onStatusChange?()
    }

    /// The picker changed; applies now if the engine is running, else at the next wake.
    @MainActor
    public func selectInput(uid: String?) {
        selection.choose(uid)  // also forgets unstable devices: picking one is a retry
        budget.reset()
        inputDevicesChanged()
    }

    /// For Settings: the device recording (or expected to), whether a chosen device is absent
    /// or failed so the system default stands in, and the name of a device given up on.
    @MainActor
    public var status: (device: AudioInputDevice?, fellBack: Bool, unstable: String?) {
        let unstable = selection.unstableStandIn(available: availableUIDs, defaultUID: defaultUID, fallbacks: fallbackUIDs)
        return (device.withLock { $0 }, fellBack, unstable.map { inputNames[$0] ?? $0 })
    }

    public func inputTransport() async -> AudioTransport {
        device.withLock { $0?.transport } ?? .other
    }

    // Pause (ui-spec §2) and idle sleep: stopping the engine is what turns the orange mic light off.
    @MainActor
    public func suspend() {
        suspended = true
        if engine.isRunning { // launched paused: never started, nothing to stop
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        state.withLock { ring in
            ring.mark = nil
            ring.carried = []
            ring.cold = false
            ring.floor = ring.written
            ring.resetChunks(active: false)
        }
        log.info("audio engine suspended")
    }

    @MainActor
    public func resume() throws {
        try startEngine()
        suspended = false  // only once running, or a route change could re-light a failed restart
    }

    @MainActor
    public var isRunning: Bool { engine.isRunning }

    // Built outside the @MainActor method: a closure inheriting main-actor isolation traps when
    // AVFAudio calls it on its realtime queue.
    private nonisolated func makeTap() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            let mono = AudioConversion.downmix(buffer)
            let rms = AudioLevel.rms(mono)
            self?.state.withLock { ring in
                ring.append(mono)
                ring.note(rms: rms)
            }
            self?.publishLevels(mono, rate: buffer.format.sampleRate)
        }
    }

    // Realtime thread: sums under a short uncontended lock, then a non-blocking yield outside
    // it. The stream keeps only the newest value, so a buffer spanning two chunks yields the last.
    private nonisolated func publishLevels(_ mono: [Float], rate: Double) {
        let chunk = max(Int(rate / AudioLevel.rate), 1)
        let ready = levelSink.withLock { sink -> (AsyncStream<Float>.Continuation, Float)? in
            guard let continuation = sink.continuation else { return nil }
            var level: Float?
            for sample in mono {
                sink.sum += sample * sample
                sink.count += 1
                if sink.count == chunk {
                    level = AudioLevel.normalised(rms: (sink.sum / Float(chunk)).squareRoot())
                    sink.published += 1
                    sink.sum = 0
                    sink.count = 0
                }
            }
            return level.map { (continuation, $0) }
        }
        if let (continuation, level) = ready { continuation.yield(level) }
    }

    public func levels() -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
        let (id, previous) = levelSink.withLock { sink in
            let previous = sink.continuation
            sink = LevelSink(continuation: continuation, id: sink.id + 1)
            return (sink.id, previous)
        }
        continuation.onTermination = { [weak self, log] _ in
            let published = self?.levelSink.withLock { sink -> Int? in
                guard sink.id == id else { return nil }
                defer { sink = LevelSink(id: id) }
                return sink.published
            }
            if let published { log.info("levels: publishing stopped after \(published, privacy: .public) updates") }
        }
        previous?.finish()
        log.info("levels: publishing started")
        return stream
    }

    // Bluetooth headsets drop to 16kHz HFP once the mic opens (PLAN §4): bank what we have at the
    // old rate, then restart at the new one instead of silently dropping audio. A route that
    // flaps reconfigures again on every reopen, so restarts are coalesced and budgeted (SPEC §5).
    @MainActor
    private func handleConfigurationChange() {
        guard !suspended else { return }
        if restarting { return scheduleCheck(after: RestartBudget.coalesce) }  // our own restart's echo
        let current = device.withLock { $0 } ?? lastDevice
        switch budget.configurationChanged(device: current?.uid, at: .now) {
        case .restart: restart("audio configuration changed")
        case .coalesce(let after): scheduleCheck(after: after)
        case .giveUp: giveUp(on: current)
        }
    }

    /// One trailing check for any number of coalesced changes; restarts only if the engine
    /// isn't already running at the hardware's rate (the change stopped it, or moved the rate).
    @MainActor
    private func scheduleCheck(after delay: Duration) {
        guard pendingCheck == nil else { return }
        pendingCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.pendingCheck = nil
            let rate = self.state.withLock { $0.rate }
            if self.engine.isRunning, Self.tapFormat(self.engine.inputNode)?.sampleRate == rate { return }
            self.handleConfigurationChange()
        }
    }

    /// Past the budget: skip this device (InputSelection) and restart once on the stand-in.
    @MainActor
    private func giveUp(on current: AudioInputDevice?) {
        let name = current?.name ?? "unknown"
        log.error("input \(name, privacy: .public) keeps reconfiguring; giving up on it")
        if let uid = current?.uid { selection.markUnstable(uid) }
        let next = selection.attempts(available: availableUIDs, defaultUID: defaultUID, fallbacks: fallbackUIDs)
        guard current != nil, !next.isEmpty else {
            // Nothing stable to open: leave the mic off; the next press wakes it on the default.
            log.error("no stable input left; the mic stays off until the next press")
            suspend()
            setDevice(nil)  // Settings: "keeps dropping; the mic is off", not "using" the same device
            onStatusChange?()
            return
        }
        restart("falling back from \(name)")
        if engine.isRunning, device.withLock({ $0?.uid }) != current?.uid { onInputSwitched?() }
    }

    @MainActor
    private func restart(_ reason: String) {
        guard !suspended else { return }  // Pause: a route change must not re-light the mic
        log.notice("\(reason, privacy: .public); restarting engine")
        restarting = true
        defer {
            restarting = false
            budget.restartFinished(at: .now)
        }
        let wasRecording = state.withLock { $0.bankForRestart() }
        if engine.isRunning { engine.stop() }
        do {
            try startEngine()
            if wasRecording { state.withLock { $0.mark = $0.written } }
        } catch {
            // String(describing:), not localizedDescription: that prints a Swift enum's case
            // index ("Failure error 0" was deviceSwitch, whose OSStatus it dropped).
            log.error("audio engine restart failed: \(String(describing: error), privacy: .public)")
            // Stopped, so mark it asleep: the next press cold-starts it (wakeIfSuspended) instead
            // of failing with engineNotRunning. Not suspend(): that would drop banked audio.
            suspended = true
        }
    }

    // Tail and pre-roll: the last tap buffer (~43ms) plus I/O latency lands after key-up, and
    // people start talking a beat before the key is fully down. The ring already holds both.
    private static let preRoll: Double = 0.15
    private static let tail: Duration = .milliseconds(120)

    // A press while paused or asleep restarts the engine here, then waits for the tap to carry
    // real audio so the recording (and the Listening meter) starts when the mic is live.
    @MainActor
    private func wakeIfSuspended() async throws {
        guard suspended else { return }
        if configObserver == nil { try await prewarm() } else { try resume() }
        let woke = ContinuousClock.now
        let outcome = await AudioWake.waitForInput { [weak self] in
            self?.state.withLock { $0.probe } ?? AudioWake.Probe(buffers: 1, peakRMS: 1)
        }
        state.withLock { $0.cold = true }
        let ms = Int(((ContinuousClock.now - woke) / .milliseconds(1)).rounded())
        log.info("audio engine woke for a press: \(String(describing: outcome), privacy: .public) after \(ms, privacy: .public)ms")
    }

    public func sleep() async {
        await MainActor.run { suspend() }
    }

    public func wake() async throws {
        try await wakeIfSuspended()
    }

    public func start() async throws {
        try await wakeIfSuspended()
        guard engine.isRunning else { throw AudioCaptureError.engineNotRunning }
        state.withLock { ring in
            ring.carried = []
            // Cold: everything since the engine started is post-press (the wait above). Warm:
            // 150ms of pre-roll, never reaching back past a sleep.
            ring.mark = ring.cold ? ring.startedAt : max(ring.floor, ring.written - Int(ring.rate * Self.preRoll))
            ring.cold = false
            ring.resetChunks(active: ring.chunksActive)  // a new mark: the pump starts from it
        }
    }

    /// Non-realtime pump (the tap stays as is): every 100 ms, copies what's new since its cursor
    /// under the state lock and resamples it with one long-lived converter.
    public func chunks() -> AsyncStream<SottoCore.AudioBuffer> {
        let (stream, continuation) = AsyncStream.makeStream(of: SottoCore.AudioBuffer.self)
        let (id, previous) = chunkSink.withLock { sink in
            let previous = sink.continuation
            sink = (sink.id + 1, continuation)
            return (sink.id, previous)
        }
        previous?.finish()
        state.withLock { $0.resetChunks(active: true) }
        let task = Task { [weak self, log] in
            var resampler: StreamingResampler?
            var yielded = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.chunkInterval)
                guard !Task.isCancelled else { break }  // a cancelled pump never advances the cursor
                guard let deltas = self?.state.withLock({ $0.takeChunkDeltas() }) else { break }
                var out: [Float] = []
                do {
                    for (rate, samples) in deltas where !samples.isEmpty {
                        if resampler?.sourceRate != rate { // restart at a new rate (HFP)
                            out += try resampler?.flush() ?? []
                            resampler = try StreamingResampler(sourceRate: rate)
                        }
                        out += try resampler?.process(samples) ?? []
                    }
                } catch {
                    log.error("chunks: resample failed (\(String(describing: error), privacy: .public)); stopping")
                    break
                }
                guard !out.isEmpty else { continue }
                yielded += out.count
                continuation.yield(SottoCore.AudioBuffer(samples: out, sampleRate: AudioConversion.targetRate))
            }
            continuation.finish()
            log.info("chunks: stopped after \(Double(yielded) / AudioConversion.targetRate, privacy: .public)s")
        }
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            self?.chunkSink.withLock { if $0.id == id { $0.continuation = nil } }
        }
        return stream
    }

    private func finishChunks() {
        state.withLock { $0.resetChunks(active: false) }
        chunkSink.withLock { sink in
            defer { sink.continuation = nil }
            return sink.continuation
        }?.finish()
    }

    public func stop() async throws -> SottoCore.AudioBuffer {
        finishChunks()
        try? await Task.sleep(for: Self.tail)
        // A quick tap on a slow route may not have produced a buffer yet; wait briefly for one.
        let got = await AudioWake.waitForBuffer { [weak self] in
            self?.state.withLock { ring in ring.mark.map { ring.written > $0 } ?? true || !ring.carried.isEmpty } ?? true
        }
        if !got { log.notice("stop: no buffer since the mark after \(Int((AudioWake.stopGrace / .milliseconds(1)).rounded()), privacy: .public)ms") }
        let (samples, rate, carried) = try state.withLock { ring -> ([Float], Double, [Float]) in
            // mark is nil only if a restart failed mid-record; return what was banked.
            guard let mark = ring.mark else {
                if ring.carried.isEmpty { throw Failure.notRecording }
                defer { ring.carried = [] }
                return ([], ring.rate, ring.carried)
            }
            defer {
                ring.mark = nil
                ring.carried = []
            }
            return (ring.since(mark), ring.rate, ring.carried)
        }
        // Display only: the session says "No audio from …" if nothing transcribes.
        var silent: SottoCore.AudioBuffer.SilentInput?
        if AudioWake.isDigitalSilence(carried, samples) {
            let name = device.withLock { $0?.name }
            log.notice("input \(name ?? "unknown", privacy: .public) delivered only silence")
            silent = .init(device: name)
        } else if !samples.isEmpty || !carried.isEmpty {
            Task { @MainActor [weak self] in self?.budget.reset() }  // real audio: the route is fine
        }
        let converted = try AudioConversion.to16kMono(samples, sourceRate: rate)
        return SottoCore.AudioBuffer(samples: carried + converted, sampleRate: AudioConversion.targetRate, silentInput: silent)
    }
}
