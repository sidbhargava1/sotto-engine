// FluidAudio 0.17.4 API as verified in spikes/Sources/spike/Parakeet.swift: transcribe() takes an
// explicit `decoderState: inout`, not the `source:` param the upstream docs show.
import FluidAudio
import Foundation
import SottoCore
import Synchronization
import os

/// Parakeet TDT v2 weights through FluidAudio. `ensureDownloaded` is the only fetch (ADR §5):
/// FluidAudio's `load`/`downloadAndLoad` download whatever is missing, so the transcriber loads
/// through `loadLocal()` here instead.
public actor ParakeetModelStore: ModelStore {
    public static let id = ModelID("parakeet-tdt-0.6b-v2")
    private static let version = AsrModelVersion.v2

    /// The repo folder FluidAudio downloads into and loads from.
    public nonisolated let directory: URL
    private var inFlight: Task<Void, Error>?

    /// `root` is the folder that holds model repos; nil keeps FluidAudio's own cache
    /// (Application Support/FluidAudio/Models), where existing installs already have the weights.
    public init(root: URL? = nil) {
        _ = ParakeetTranscriber.quietConsole  // before this store's first FluidAudio call
        directory = root.map { $0.appending(path: Repo.parakeetV2.folderName, directoryHint: .isDirectory) }
            ?? AsrModels.defaultCacheDirectory(for: Self.version)
    }

    private var present: Bool { AsrModels.modelsExist(at: directory, version: Self.version) }

    public func availability(for model: ModelID) -> ModelAvailability {
        guard model == Self.id else { return .failed(reason: "unknown model") }
        if inFlight != nil { return .downloading(progress: 0) }
        return present ? .ready : .notDownloaded
    }

    public func url(for model: ModelID) -> URL? { model == Self.id && present ? directory : nil }

    public func ensureDownloaded(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ensureDownloaded(model, force: false, progress: progress)
    }

    /// `force`: the files are present but `loadLocal` threw (a corrupt cache). The fresh copy lands
    /// beside the old one and replaces it only once complete, so a failed refetch loses nothing.
    public func ensureDownloaded(_ model: ModelID, force: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard model == Self.id else { throw ModelNotDownloaded(model) }
        if let inFlight { return try await inFlight.value }  // MS-05: one download, shared
        Self.sweepStaging(beside: directory)
        guard force || !present else { return }
        let directory = directory
        let task = Task {
            guard force, FileManager.default.fileExists(atPath: directory.path) else {
                _ = try await AsrModels.download(to: directory, version: Self.version) { progress($0.fractionCompleted) }
                return
            }
            // FluidAudio downloads into <parent>/<repo folder>, so stage under a scratch parent.
            let scratch = directory.deletingLastPathComponent().appending(path: ".refetch-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let staged = scratch.appending(path: directory.lastPathComponent, directoryHint: .isDirectory)
            _ = try await AsrModels.download(to: staged, force: true, version: Self.version) { progress($0.fractionCompleted) }
            guard AsrModels.modelsExist(at: staged, version: Self.version) else { throw ModelNotDownloaded(Self.id) }
            _ = try FileManager.default.replaceItemAt(directory, withItemAt: staged)
        }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    /// A refetch killed mid-download (quit, crash) leaves its scratch folder; nothing else owns them.
    static func sweepStaging(beside directory: URL) {
        let parent = directory.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(".refetch-") {
            try? FileManager.default.removeItem(at: parent.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// Never fetches; a load that races the explicit download waits for it rather than failing.
    func loadLocal() async throws -> AsrModels {
        if let inFlight { try await inFlight.value }
        guard present else { throw ModelNotDownloaded(Self.id) }
        return try AsrModels.loadLocal(from: directory, version: Self.version)
    }
}

public actor ParakeetTranscriber: PrewarmingTranscriber {
    public nonisolated let models: ParakeetModelStore
    private let log: Logger
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    /// Finals running now. During DS-02, utterance B records while A's final runs; B's partial
    /// ticks skip so A's final never queues behind them on the ANE.
    private var finalsInFlight = 0
    /// The partial tick on the ANE now, if any: cancelling its task doesn't stop CoreML, so a final
    /// that starts meanwhile queues behind it. Logged per final (counts and ms only).
    private var tickStartedAt: ContinuousClock.Instant?
    private var tickEndedAt: ContinuousClock.Instant?

    /// Partials cadence: re-run TDT on the growing buffer (spikes/stream/RESULTS.md approach A).
    public static let partialCadence = 0.4

    /// FluidAudio mirrors its log lines to stderr by default (every level in Debug builds, ASR debug
    /// lines with transcript text among them). The engine turns that off on first use, so no host
    /// prints transcripts by accident; the lines still reach the unified log, where text is private.
    /// A host that wants them on stderr sets this to true.
    public static var mirrorsLogsToConsole: Bool {
        get {
            _ = quietConsole
            return AppLogger.mirrorsToConsole
        }
        set {
            _ = quietConsole  // so a later first init can't undo the host's choice
            AppLogger.mirrorsToConsole = newValue
        }
    }

    /// Applied once, before the first FluidAudio call any engine type makes.
    static let quietConsole: Void = { AppLogger.mirrorsToConsole = false }()

    public init(models: ParakeetModelStore, log: LogSubsystem) {
        _ = Self.quietConsole
        self.models = models
        self.log = log.logger("stt")
    }

    public nonisolated var modelSource: ModelSource { ModelSource(store: models, id: ParakeetModelStore.id) }

    /// Cold CoreML/ANE load takes seconds; do it at launch, not on first hotkey (CLAUDE.md).
    /// Throws `ModelNotDownloaded` until the host has called `ensureDownloaded`.
    public func prewarm() async throws {
        _ = try await loadedManager()
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { [models] () throws -> AsrManager in
            let loaded = try await models.loadLocal()
            let m = AsrManager(config: .default)
            try await m.loadModels(loaded)
            return m
        }
        loading = task
        do {
            let m = try await task.value
            manager = m
            loading = nil
            log.info("parakeet loaded")
            return m
        } catch {
            loading = nil
            throw error
        }
    }

    private func run(_ samples: [Float]) async throws -> String {
        let manager = try await loadedManager()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &decoderState).text
    }

    private func beginFinal() -> ContinuousClock.Instant? {
        finalsInFlight += 1
        return tickStartedAt
    }
    private func tickBegan() { tickStartedAt = .now }
    private func tickEnded() {
        tickStartedAt = nil
        tickEndedAt = .now
    }

    private func logFinal(started: ContinuousClock.Instant, tickStarted: ContinuousClock.Instant?) {
        let ms = { (d: Duration) in Int((d / .milliseconds(1)).rounded()) }
        let total = ms(.now - started)
        guard let tickStarted else { return log.info("final: ms=\(total, privacy: .public) tickInFlight=false") }
        // The tick's end relative to the final's start; "outlived" means it was still running when the final finished.
        let tickEnd = tickEndedAt.flatMap { $0 > tickStarted ? String(ms($0 - started)) : nil } ?? "outlived"
        log.info("final: ms=\(total, privacy: .public) tickInFlight=true tickAgeMs=\(ms(started - tickStarted), privacy: .public) tickEndMs=\(tickEnd, privacy: .public)")
    }
    private func endFinal() { finalsInFlight -= 1 }
    private func finalRunning() -> Bool { finalsInFlight > 0 }

    public nonisolated func transcribe(_ buffer: AudioBuffer) -> AsyncThrowingStream<TranscriptChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let started = ContinuousClock.now
                let tickStarted = await self.beginFinal()
                do {
                    let text = try await self.run(buffer.samples)
                    await self.endFinal()
                    await self.logFinal(started: started, tickStarted: tickStarted)
                    continuation.yield(TranscriptChunk(text: text, isFinal: true))
                    continuation.finish()
                } catch {
                    await self.endFinal()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: partials (display-only; text never logged)

    /// Off in Low Power Mode and at serious/critical thermal state (RESULTS.md condition 5).
    public static func partialsAllowed(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        !lowPower && thermal != .serious && thermal != .critical
    }

    private static func partialsAllowedNow() -> Bool {
        partialsAllowed(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }

    public nonisolated func partials(_ audio: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<PartialTranscript, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { await self.streamPartials(audio, to: continuation) }
            continuation.onTermination = { _ in task.cancel() }  // cancels the in-flight tick too
        }
    }

    private nonisolated func streamPartials(_ audio: AsyncStream<AudioBuffer>, to continuation: AsyncThrowingStream<PartialTranscript, Error>.Continuation) async {
        guard Self.partialsAllowedNow() else {
            log.info("partials: off (low power or thermal)")
            continuation.finish()
            return
        }
        let tick = PartialTick()
        var samples: [Float] = []
        var onset = OnsetDetector()
        var nextTick = Self.partialCadence
        var counts = (beforeOnset: 0, busy: 0, final: 0)
        var ended = "release"
        await withTaskGroup(of: Void.self) { group in
            for await chunk in audio {
                samples += chunk.samples
                onset.feed(chunk.samples)
                let seconds = Double(samples.count) / AudioConversion.targetRate
                guard seconds >= nextTick else { continue }
                nextTick = (seconds / Self.partialCadence).rounded(.down) * Self.partialCadence + Self.partialCadence
                if seconds >= PartialStabilizer.maxAudioSeconds { ended = "ceiling"; break }
                if tick.stopped { ended = "error"; break }
                guard let onsetAt = onset.onset else { counts.beforeOnset += 1; continue }
                guard Self.partialsAllowedNow() else { ended = "power"; break }
                if await self.finalRunning() { counts.final += 1; continue }
                guard tick.claim() else { counts.busy += 1; continue }
                let snapshot = samples
                group.addTask {
                    let started = ContinuousClock.now
                    await self.tickBegan()
                    let result: Result<String, Error>
                    do { result = .success(try await self.run(snapshot)) } catch { result = .failure(error) }
                    await self.tickEnded()
                    do {
                        let text = try result.get()
                        try Task.checkCancellation()
                        if let partial = tick.finish(text, audioSeconds: seconds, onset: onsetAt, took: .now - started) {
                            continuation.yield(partial)
                        }
                    } catch {
                        tick.fail(Task.isCancelled ? nil : error)
                    }
                }
            }
            group.cancelAll()
        }
        let s = tick.summary
        // Audio-time ms from the capture mark; "-" = never. Counts and times only, never text.
        let ms = { (t: Double?) in t.map { String(Int(($0 * 1000).rounded())) } ?? "-" }
        log.info("partials: \(ended, privacy: .public) after \(Double(samples.count) / AudioConversion.targetRate, privacy: .public)s onsetMs=\(ms(onset.onset), privacy: .public) firstShownMs=\(ms(s.firstShown), privacy: .public) runs=\(s.runs, privacy: .public) shown=\(s.shown, privacy: .public) maxMs=\(s.maxMs, privacy: .public) skipped onset=\(counts.beforeOnset, privacy: .public) busy=\(counts.busy, privacy: .public) final=\(counts.final, privacy: .public)")
        if let error = s.error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}

/// One utterance's partials: the single in-flight slot, the stabilizer, and counters for the log.
private final class PartialTick: Sendable {
    private struct State {
        var busy = false
        var stabilizer = PartialStabilizer()
        var stopped = false
        var error: Error?
        var runs = 0
        var shown = 0
        var maxMs = 0
        var firstShown: Double?  // audio seconds of the first snapshot shown
    }
    private let state = Mutex(State())

    var stopped: Bool { state.withLock { $0.stopped } }
    var summary: (runs: Int, shown: Int, maxMs: Int, firstShown: Double?, error: Error?) {
        state.withLock { ($0.runs, $0.shown, $0.maxMs, $0.firstShown, $0.error) }
    }

    /// Drops the tick if the previous call is still running.
    func claim() -> Bool {
        state.withLock { s in
            guard !s.busy else { return false }
            s.busy = true
            return true
        }
    }

    func finish(_ text: String, audioSeconds: Double, onset: Double, took: Duration) -> PartialTranscript? {
        state.withLock { s in
            s.busy = false
            s.runs += 1
            s.maxMs = max(s.maxMs, Int((took / .milliseconds(1)).rounded()))
            switch s.stabilizer.ingest(text, audioSeconds: audioSeconds, onset: onset) {
            case .show(let partial):
                s.shown += 1
                if s.firstShown == nil { s.firstShown = partial.audioSeconds }
                return partial
            case .hold: return nil
            case .stop:
                s.stopped = true
                return nil
            }
        }
    }

    func fail(_ error: Error?) {
        state.withLock { s in
            s.busy = false
            if let error {
                s.error = error
                s.stopped = true
            }
        }
    }
}
