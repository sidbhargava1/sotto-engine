// The engine as an outside host sees it: no @testable, so this only compiles while every adapter
// the engine-docs README quick start uses is public. Nothing here downloads, records or types.
import AVFoundation
import SottoCore
import SottoEngine
import XCTest

final class PublicSurfaceTests: XCTestCase {
    final class Trigger: HotkeyMonitoring {
        let (stream, edges) = AsyncStream.makeStream(of: HotkeyEvent.self)
        func events() -> AsyncStream<HotkeyEvent> { stream }
    }

    actor MemorySettings: SettingsStore {
        private var settings = Settings()
        func load() -> Settings { settings }
        func save(_ settings: Settings) { self.settings = settings }
    }

    /// FluidAudio defaults to mirroring logs (Debug: transcript text) to stderr; the engine doesn't.
    func test_fluidAudioConsoleMirroringIsOffByDefault() {
        _ = ParakeetModelStore(root: FileManager.default.temporaryDirectory)
        XCTAssertFalse(ParakeetTranscriber.mirrorsLogsToConsole)
    }

    @MainActor
    func test_quickStartBuildsFromPublicAPI() async throws {
        let log = LogSubsystem("sotto-engine.tests")
        let base = FileManager.default.temporaryDirectory.appending(path: "sotto-engine-public-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let models = FileModelStore(directory: base.appending(path: "Models"), allowFetch: false, log: log)
        let qwen = await models.availability(for: ModelSpec.qwen3_4b.id)
        XCTAssertEqual(qwen, .notDownloaded)
        _ = ModelSpec(id: ModelID("x"), fileName: "x.gguf", url: base, sha256: "", size: 0, displayName: "X")
        let cleanup = LocalCleanupBackend()
        let llm = LlamaBackend.make(modelURL: base.appending(path: "absent.gguf"), log: log)  // not loaded
        cleanup.install(llm)

        let audio = AVAudioEngineCapture(log: log, preferredInputUID: nil)
        let transcriber = SwitchingTranscriber(.parakeet, parakeetRoot: base, log: log)
        let stt = await transcriber.modelAvailability()
        XCTAssertEqual(stt, .notDownloaded, "a fresh root has no weights, and asking never fetches")
        let parakeet = ParakeetTranscriber(models: ParakeetModelStore(root: base), log: log)
        _ = SwitchingTranscriber(.parakeet, parakeet: parakeet, apple: nil)
        _ = ModelSource(store: models, id: ModelSpec.qwen3_4b.id)
        if #available(macOS 26, *) { _ = SpeechAnalyzerTranscriber(assets: SpeechAssetStore()) }

        let session = DictationSession(
            hotkey: Trigger(), audio: audio, transcriber: transcriber, cleanup: cleanup,
            injectors: InjectorChain([
                (.axSelectedText, AXSelectedTextInjector(log: log)), (.paste, PasteInjector()), (.unicodeType, UnicodeTypeInjector()),
            ]),
            contextProvider: WorkspaceContextProvider(log: log),
            dictionaryStore: FileDictionaryStore(url: base.appending(path: "dictionary.txt")),
            settingsStore: MemorySettings(),
            clipboard: PasteboardClipboard(), undo: SystemUndo())
        _ = session

        // The rest of the adapter set a host composes.
        _ = DryRunInjector(log: log)
        let wav = base.appending(path: "tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try AudioConversion.pcmBuffer([Float](repeating: 0.1, count: 1_600), format: format)
        try AVAudioFile(forWriting: wav, settings: format.settings).write(from: buffer)
        let fixture = try FixtureAudioCapture(url: wav, log: log)
        XCTAssertEqual(fixture.samples.count, 1_600)
        _ = DirectoryWatcher(base) {}
        _ = AudioDevices.inputs()
        _ = AccessibilityFocus.focusedElement(appPID: nil)

        cleanup.install(nil)
        await llm.shutdown()
    }
}
