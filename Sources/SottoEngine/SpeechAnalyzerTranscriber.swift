// Second STT engine behind #available so one build can A/B against Parakeet (PLAN §1, §2).
// API per spikes/Sources/spike/AppleSpeech.swift, verified against the SDK 26.2 interface.
import AVFoundation
import Speech
import SottoCore

/// The system's on-device speech assets for one locale. `ensureDownloaded` is the only install
/// (ADR §5); the transcriber refuses to run until they're present.
@available(macOS 26, *)
public actor SpeechAssetStore: ModelStore {
    public static let id = ModelID("speechanalyzer-transcription")
    public enum Failure: Error { case assetUnavailable }

    public nonisolated let locale: Locale
    private var inFlight: Task<Void, Error>?

    public init(locale: Locale = Locale(identifier: "en-US")) { self.locale = locale }

    nonisolated func module() -> SpeechTranscriber { SpeechTranscriber(locale: locale, preset: .transcription) }

    private func installed() async -> Bool { await AssetInventory.status(forModules: [module()]) == .installed }

    public func availability(for model: ModelID) async -> ModelAvailability {
        guard model == Self.id else { return .failed(reason: "unknown model") }
        if inFlight != nil { return .downloading(progress: 0) }
        return await installed() ? .ready : .notDownloaded
    }

    public func url(for model: ModelID) -> URL? { nil }  // system-managed

    public func ensureDownloaded(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard model == Self.id else { throw ModelNotDownloaded(model) }
        if let inFlight { return try await inFlight.value }  // MS-05
        guard !(await installed()) else { return }
        let module = module()
        let task = Task {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                throw Failure.assetUnavailable
            }
            try await request.downloadAndInstall()
            progress(1)
        }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    /// Never installs; waits out an install already running so a press during it isn't lost.
    func requireInstalled() async throws {
        if let inFlight { try await inFlight.value }
        guard await installed() else { throw ModelNotDownloaded(Self.id) }
    }
}

@available(macOS 26, *)
public struct SpeechAnalyzerTranscriber: PrewarmingTranscriber {
    public enum Failure: Error { case noAudioFormat }

    public let assets: SpeechAssetStore

    public init(assets: SpeechAssetStore) { self.assets = assets }

    public var modelSource: ModelSource { ModelSource(store: assets, id: SpeechAssetStore.id) }

    /// Throws `ModelNotDownloaded` until the host has called `ensureDownloaded`.
    public func prewarm() async throws {
        try await assets.requireInstalled()
    }

    private func run(_ samples: [Float]) async throws -> String {
        let transcriber = assets.module()
        try await assets.requireInstalled()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
            let source = AudioConversion.monoFormat(AudioConversion.targetRate)
        else { throw Failure.noAudioFormat }

        let pcm = try AudioConversion.pcmBuffer(samples, format: source)
        let converted = format == source ? pcm : try AudioConversion.convert(pcm, to: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task<String, Error> {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        let input = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(AnalyzerInput(buffer: converted))
            continuation.finish()
        }
        _ = try await analyzer.analyzeSequence(input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    public func transcribe(_ buffer: SottoCore.AudioBuffer) -> AsyncThrowingStream<TranscriptChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await run(buffer.samples)
                    continuation.yield(TranscriptChunk(text: text, isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
