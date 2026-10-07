// Picks the STT engine per utterance so a Settings change applies from the next one
// (ui-spec §4) without rebuilding DictationSession.
import Foundation
import SottoCore
import Synchronization

/// The weights an engine loads and the store that fetches them (ADR §5).
public struct ModelSource: Sendable {
    public let store: any ModelStore
    public let id: ModelID

    public init(store: any ModelStore, id: ModelID) {
        self.store = store
        self.id = id
    }
}

/// Engines SwitchingTranscriber can warm at launch and on a Settings switch.
public protocol PrewarmingTranscriber: Transcribing {
    /// Loads weights already on disk; throws `ModelNotDownloaded` rather than fetching (ADR §5).
    func prewarm() async throws
    var modelSource: ModelSource { get }
}

public final class SwitchingTranscriber: Transcribing {
    private let parakeet: any PrewarmingTranscriber
    private let apple: (any PrewarmingTranscriber)?
    private let current: Mutex<STTEngine>

    /// `parakeetRoot`: where Parakeet's weights live (nil: FluidAudio's own cache).
    public convenience init(_ engine: STTEngine, parakeetRoot: URL? = nil, log: LogSubsystem) {
        let apple: (any PrewarmingTranscriber)?
        if #available(macOS 26, *) { apple = SpeechAnalyzerTranscriber(assets: SpeechAssetStore()) } else { apple = nil }
        self.init(engine, parakeet: ParakeetTranscriber(models: ParakeetModelStore(root: parakeetRoot), log: log), apple: apple)
    }

    public init(_ engine: STTEngine, parakeet: any PrewarmingTranscriber, apple: (any PrewarmingTranscriber)?) {
        self.parakeet = parakeet
        self.apple = apple
        current = Mutex(engine)
    }

    /// Applies from the next utterance; the host then fetches and warms (`ensureDownloaded`, `prewarm`).
    public func select(_ engine: STTEngine) {
        current.withLock { $0 = engine }
    }

    /// The explicit fetch of the selected engine's weights, a no-op once present: the only network
    /// call STT makes (ADR §5). `force` replaces weights that are present but fail to load.
    public func ensureDownloaded(force: Bool = false, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let source = selected().modelSource
        try await source.store.ensureDownloaded(source.id, force: force, progress: progress)
    }

    public func prewarm() async throws {
        try await selected().prewarm()
    }

    /// The selected engine's weights, as its store reports them.
    public func modelAvailability() async -> ModelAvailability {
        let source = selected().modelSource
        return await source.store.availability(for: source.id)
    }

    private func selected() -> any PrewarmingTranscriber {
        if current.withLock({ $0 }) == .appleSpeechAnalyzer, let apple { return apple }
        return parakeet
    }

    /// The session resolves this at press and uses it for partials and the final alike.
    public func engineForUtterance() -> any Transcribing { selected() }

    public func transcribe(_ buffer: AudioBuffer) -> AsyncThrowingStream<TranscriptChunk, Error> {
        selected().transcribe(buffer)
    }

    // Explicit: the protocol default would silently make this wrapper batch-only (RESULTS.md).
    public func partials(_ audio: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<PartialTranscript, Error> {
        selected().partials(audio)
    }
}
