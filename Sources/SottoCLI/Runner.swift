// One dictation through the engine's public API, the same DictationSession the app runs, with
// the CLI's adapters around it (CLI.md). Built on plain `import SottoCore` / `import SottoEngine`
// only: this file is the reference for what a host has to compose.
import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import SottoCore
import SottoEngine
import Synchronization

final class Runner {
    private let invocation: Invocation
    private let console: Console
    private let log = LogSubsystem.engine
    private var llm: ModelCleanupBackend?

    init(_ invocation: Invocation) {
        self.invocation = invocation
        console = Console(quiet: invocation.quiet)
    }

    /// Before exit, always: llama.cpp's Metal teardown aborts if a context outlives the process.
    func shutdown() async {
        await llm?.shutdown()
        llm = nil
    }

    func run() async -> ExitCode {
        // The app `sotto` was typed into, read before anything can move focus (LaunchingAppPolicy).
        let launchApp = invocation.inject ? await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier } : nil
        // Input first: a bad path should fail before anything loads.
        var file: CappedFileCapture?
        if case .transcribe(let url) = invocation.command {
            switch Self.openWAV(url, log: log) {
            case .success(let capture): file = capture
            case .failure(let message):
                console.error(message)
                return .noInput
            }
        }
        var terms: [DictionaryTerm] = []
        if let url = invocation.dictionary {
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let loaded = try? await FileDictionaryStore(url: url).load()
            else {
                console.error("cannot read dictionary \(url.path)")
                return .noInput
            }
            terms = loaded
        }

        let transcriber: SwitchingTranscriber
        switch await prepareModels(terms: terms) {
        case .success(let ready): transcriber = ready
        case .failure(let code): return code
        }

        // After the model check, so a run that exits 69 never prompts. Missing permission is
        // reported once, at the end (Outcome).
        let output: OutputMode = invocation.inject ? (Self.accessibilityTrusted(prompt: true) ? .inject : .clipboard) : .stdout

        let audio: any AudioCapturing
        if let file {
            if file.isOverCap { console.warn("the recording is longer than 60 s; transcribing the first 60 s") }
            audio = file
        } else {
            let mic = AVAudioEngineCapture(log: log, preferredInputUID: invocation.input)
            if let uid = invocation.input, !AudioDevices.inputs().contains(where: { $0.device.uid == uid }) {
                console.warn("no input device with UID \(uid); using the system default")
            }
            do {
                try await mic.prewarm()
            } catch AVAudioEngineCapture.Failure.micDenied {
                console.error("microphone access denied; allow it for this terminal in System Settings → Privacy & Security → Microphone")
                return .noPermission
            } catch {
                console.error("could not start the microphone: \(error)")
                return .nothingRecognised
            }
            audio = mic
        }

        let sink = OutputSink()
        let cleanup = LocalCleanupBackend()
        if let llm, llm.isReady { cleanup.install(llm) }  // not ready: the session goes raw (degraded)
        let trigger = OneShotTrigger()
        let session = DictationSession(
            hotkey: trigger, audio: audio, transcriber: transcriber, cleanup: cleanup,
            injectors: output == .inject
                ? InjectorChain([
                    (.axSelectedText, AXSelectedTextInjector(log: log)),
                    (.paste, PasteInjector()),
                    (.unicodeType, UnicodeTypeInjector()),
                ])
                : InjectorChain([]),
            injectionPolicy: LaunchingAppPolicy(launchApp: launchApp),
            contextProvider: output == .inject ? ReleaseTimeContext(base: WorkspaceContextProvider(log: log)) : NoTargetContext(),
            dictionaryStore: FixedDictionary(terms: terms),
            settingsStore: MemorySettings(Settings(
                sttEngine: invocation.engine == .apple ? .appleSpeechAnalyzer : .parakeet,
                cleanupEngine: invocation.raw ? .raw : .local
            )),
            clipboard: output == .inject ? PasteboardClipboard() : sink,
            undo: NoUndo(),
            livePartials: false,
            logSubsystem: log,
            voiceCommands: false  // one dictation per run: nothing earlier to scratch (CLI.md)
        )

        let states = await runUtterance(session, trigger: trigger, live: file == nil)
        await session.stopMonitoring()

        let text = output == .inject ? nil : await sink.text
        let outcome = Outcome.evaluate(states: states, output: output, text: text)
        if outcome.code == .ok, let text {
            if output == .clipboard { await PasteboardClipboard().copy(text) } else { Console.result(text) }
        }
        for warning in outcome.warnings { console.warn(warning) }
        if let error = outcome.error { console.error(error) }
        return outcome.code
    }

    /// Press, release (Enter or the session's 60 s cap for `dictate`, at once for a file), and the
    /// states until the session is idle again.
    private func runUtterance(_ session: DictationSession, trigger: OneShotTrigger, live: Bool) async -> [SessionState] {
        let updates = await session.stateUpdates()
        await session.start()
        trigger.edges.yield(.pressed)
        let entered = Mutex(false)
        var seen: [SessionState] = []
        for await state in updates {
            seen.append(state)
            switch state {
            case .recording where live:
                console.status("listening; press Enter to stop")
                let edges = trigger.edges
                // A thread, not a task: readLine blocks, and the cooperative pool is small.
                Thread {
                    _ = readLine()  // Enter, or end of input
                    entered.withLock { $0 = true }
                    edges.yield(.released)
                }.start()
            case .recording:
                trigger.edges.yield(.released)
            case .transcribing:
                if live, !entered.withLock({ $0 }) { console.warn("stopped at the 60 s limit") }
                console.status("transcribing")
            case .cleaning where !invocation.raw:
                console.status("cleaning up")
            case .idle:
                return seen
            default:
                break
            }
        }
        return seen
    }

    // MARK: models

    /// Checks every model this run needs, fetches only with `--download` (no other network access), and loads them.
    private func prepareModels(terms: [DictionaryTerm]) async -> Result<SwitchingTranscriber, ExitCode> {
        let dir = invocation.models
        var transcriber: SwitchingTranscriber
        let sttLabel: String
        // Set when Parakeet comes from FluidAudio's shared cache: then `own` is where a fetch goes.
        var sharedFallback: ParakeetModelStore?
        switch invocation.engine {
        case .parakeet:
            let own = ParakeetModelStore(root: dir)
            var store = own
            // Reuse weights another FluidAudio host (the Sotto app among them) already has, read-only:
            // the CLI never calls ensureDownloaded on that store, since it is another app's live copy.
            if await own.availability(for: ParakeetModelStore.id) != .ready {
                let shared = ParakeetModelStore(root: nil)
                if await shared.availability(for: ParakeetModelStore.id) == .ready {
                    store = shared
                    sharedFallback = own
                    console.status("using Parakeet from FluidAudio's cache at \(shared.directory.path)")
                }
            }
            transcriber = SwitchingTranscriber(.parakeet, parakeet: ParakeetTranscriber(models: store, log: log), apple: nil)
            sttLabel = "Parakeet TDT 0.6B v2 (about 450 MB) in \(own.directory.path)"
        case .apple:
            guard #available(macOS 26, *) else {
                console.error("--engine apple needs macOS 26 (SpeechAnalyzer)")
                return .failure(.unavailable)
            }
            transcriber = SwitchingTranscriber(
                .appleSpeechAnalyzer,
                parakeet: ParakeetTranscriber(models: ParakeetModelStore(root: dir), log: log),
                apple: SpeechAnalyzerTranscriber(assets: SpeechAssetStore())
            )
            sttLabel = "Apple SpeechAnalyzer assets for en-US (system-managed)"
        }
        let gguf = FileModelStore(directory: dir, allowFetch: invocation.download, log: log)
        let qwen = ModelSpec.qwen3_4b

        var missing: [String] = []
        let sttMissing = await transcriber.modelAvailability() != .ready
        if sttMissing { missing.append(sttLabel) }
        let ggufMissing = invocation.raw ? false : await gguf.availability(for: qwen.id) != .ready
        if ggufMissing { missing.append("\(qwen.displayName) cleanup model (2.5 GB) at \(dir.appending(path: qwen.fileName).path)") }

        if !missing.isEmpty, !invocation.download {
            for item in missing { console.error("missing \(item)") }
            console.error("re-run with --download to fetch \(missing.count == 1 ? "it" : "them")"
                + (ggufMissing ? ", or --raw to skip cleanup" : "")
                + (invocation.models == Arguments.defaultModels || !(ggufMissing || (sttMissing && invocation.engine == .parakeet)) ? "" : ", or check --models"))
            return .failure(.unavailable)
        }
        do {
            if sttMissing {
                let progress = console.progress(invocation.engine == .parakeet ? "Parakeet" : "SpeechAnalyzer assets")
                defer { progress.finish() }
                try await transcriber.ensureDownloaded(progress: progress.update)
            }
            if ggufMissing {
                let progress = console.progress(qwen.displayName)
                defer { progress.finish() }
                try await gguf.ensureDownloaded(qwen.id, progress: progress.update)
            }
        } catch FileModelStore.Failure.checksum {
            console.error("the \(qwen.displayName) download failed its checksum; re-run to fetch it again")
            return .failure(.unavailable)
        } catch {
            console.error("model download failed: \(error)")
            return .failure(.unavailable)
        }

        console.status("loading models")
        do {
            try await transcriber.prewarm()
        } catch {
            // Present but unloadable (an interrupted fetch): only --download may replace it.
            guard invocation.download else {
                console.error("the speech model failed to load (\(error)); re-run with --download to fetch it again")
                return .failure(.unavailable)
            }
            do {
                let progress = console.progress("speech model")
                defer { progress.finish() }
                if let own = sharedFallback {
                    // The shared copy won't load: fetch a fresh one into <dir>, never over the shared cache.
                    transcriber = SwitchingTranscriber(.parakeet, parakeet: ParakeetTranscriber(models: own, log: log), apple: nil)
                    try await transcriber.ensureDownloaded(progress: progress.update)
                } else {
                    try await transcriber.ensureDownloaded(force: true, progress: progress.update)
                }
                try await transcriber.prewarm()
            } catch {
                console.error("the speech model failed to load: \(error)")
                return .failure(.unavailable)
            }
        }

        if !invocation.raw, let url = await gguf.url(for: qwen.id) {
            let backend = LlamaBackend.make(modelURL: url, log: log)
            llm = backend
            do {
                try await backend.load(dictionary: terms.map(\.text))
            } catch {
                // Recognised speech is never dropped: the session falls back to raw (CLI.md).
                console.warn("the cleanup model failed to load (\(error)); output will be the raw transcript")
            }
        }
        return .success(transcriber)
    }

    // MARK: input

    enum OpenResult {
        case success(CappedFileCapture)
        case failure(String)
    }

    static func openWAV(_ url: URL, log: LogSubsystem) -> OpenResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure("no such file: \(url.path)")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure("cannot read \(url.path)") }
        let header = (try? handle.read(upToCount: 12)) ?? Data()
        try? handle.close()
        guard WAV.isWAV(header: header) else { return .failure("not a WAV file: \(url.path)") }
        do {
            return .success(CappedFileCapture(try FixtureAudioCapture(url: url, log: log)))
        } catch {
            if let audio = try? AVAudioFile(forReading: url), audio.length == 0 { return .success(CappedFileCapture(nil)) }
            return .failure("cannot decode \(url.path): \(error)")
        }
    }

    /// CLI.md: asked at launch with the prompt on, so macOS offers System Settings. The grant
    /// belongs to the terminal running `sotto`, not to `sotto`.
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }
}
