# Sotto Engine

On-device voice dictation for macOS, as a Swift library. You tell it when to start and stop listening, and clean text lands at the caret of whatever app has focus, with speech recognition and cleanup running on your Mac.

Sotto Engine is for developers building their own surface: a terminal tool, a custom HUD, an agent harness. It's the engine inside the [Sotto](https://github.com/sidbhargava1/sotto-releases) app, published under Apache-2.0.

## What you get

The pipeline is hear → understand → type, and every stage is a protocol you can swap.

- **Hear.** Microphone capture through AVAudioEngine, resampled to 16 kHz mono, with input-device selection and an idle sleep so the mic light goes out between dictations. Speech-to-text runs on-device: NVIDIA Parakeet TDT 0.6B v2 through [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine (the default), or Apple's SpeechAnalyzer on macOS 26.
- **Understand.** A local cleanup pass removes fillers, adds punctuation, resolves self-corrections ("Tuesday, no, Wednesday") and turns clearly spoken lists into lists. It runs Qwen3-4B-Instruct in-process through llama.cpp, with the system prompt kept in the KV cache between utterances. If cleanup fails or stalls, you get the raw transcript, never nothing.
- **Type.** Text is inserted at the caret through the Accessibility API (`kAXSelectedTextAttribute`), so it never replaces what's already in the field. Paste and Unicode typing are the fallbacks; the clipboard is the last resort. Injection never presses Return, so dictating into a shell can't run a command.
- **Dictionary.** A plain list of names and terms that the cleanup prompt spells your way, plus heard-as rewrites for words the recogniser gets wrong.
- **Voice commands.** "Scratch that" undoes the last dictation with a guarded ⌘Z: only in the same app and the same text field, only within 30 seconds, and never in a terminal. Commands are matched on the raw transcript, before cleanup.

## Privacy

The engine makes no network calls of its own. Models are downloaded on first use, and only when you call `ModelStore.ensureDownloaded` (CLI: `--download`). After that it runs offline.

No telemetry. It never writes transcripts to disk.

Logs carry word counts and timings, never text. There is no history store; the session emits an "utterance completed" event, and keeping anything is your decision.

## Requirements

- macOS 15 or later, Apple silicon or Intel (llama.cpp ships as a universal binary; tested on Apple silicon only)
- Xcode 26 (the macOS 26 SDK is needed for SpeechAnalyzer; Command Line Tools alone won't build it)
- About 2.5 GB of disk for the cleanup model, downloaded on first use:
  - Source: `https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
  - File: `Qwen3-4B-Instruct-2507-Q4_K_M.gguf`, 2,497,281,120 bytes
  - sha256: `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`
  - The download resumes after an interruption and only becomes the real file once the checksum matches.
- The Parakeet Core ML model from [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml), downloaded the same way: on first use, and only through `ModelStore.ensureDownloaded` (`ParakeetModelStore`; `SwitchingTranscriber.ensureDownloaded()` fetches the selected engine's weights). About 450 MB on disk. `prewarm()` and `transcribe()` never download; they throw `ModelNotDownloaded`.
- In the library, you choose the model directories: `FileModelStore(directory:)` for the GGUF, `ParakeetModelStore(root:)` (or `SwitchingTranscriber(_:parakeetRoot:log:)`) for Parakeet, where nil keeps FluidAudio's own cache.
- At runtime, the host app needs Microphone permission and, to type into other apps, Accessibility. Without Accessibility, results go to the clipboard.

## Install

```swift
.package(url: "https://github.com/sidbhargava1/sotto-engine", .upToNextMinor(from: "0.1.0")),
```

Then depend on `SottoCore` (pure logic and protocols) and `SottoEngine` (the macOS adapters). llama.cpp ships as a prebuilt `llama.xcframework` attached to each release, which SwiftPM fetches and verifies by checksum; you don't need cmake. To build it from source instead, run `scripts/build-llama.sh` in a checkout: a `Vendor/llama.xcframework` there takes precedence.

## Quick start

The engine has no global hotkey; that adapter lives in the app. Anything that emits press and release edges will do:

Every adapter takes a `LogSubsystem`, so engine logs land under your subsystem (categories `session`, `stt`, `llm`, `audio`, …). Settings persistence is yours too: anything conforming to `SettingsStore` will do.

```swift
import SottoCore
import SottoEngine

final class Trigger: HotkeyMonitoring {
    let (stream, edges) = AsyncStream.makeStream(of: HotkeyEvent.self)
    func events() -> AsyncStream<HotkeyEvent> { stream }
}

actor MemorySettings: SettingsStore {
    private var settings = Settings()                 // Parakeet + local cleanup by default
    func load() -> Settings { settings }
    func save(_ settings: Settings) { self.settings = settings }
}

let log = LogSubsystem("com.example.myapp")
let base = URL.applicationSupportDirectory.appending(path: "MyApp")
let models = FileModelStore(directory: base.appending(path: "Models"), log: log)
try await models.ensureDownloaded(ModelSpec.qwen3_4b.id) { _ in }      // explicit download: cleanup
let cleanup = LocalCleanupBackend()
let llm = LlamaBackend.make(modelURL: await models.url(for: ModelSpec.qwen3_4b.id)!, log: log)
try await llm.load(dictionary: [])
cleanup.install(llm)

let trigger = Trigger()
let audio = AVAudioEngineCapture(log: log)
try await audio.prewarm()
let transcriber = SwitchingTranscriber(.parakeet, parakeetRoot: base.appending(path: "Models"), log: log)
try await transcriber.ensureDownloaded()                                 // explicit download: STT
try await transcriber.prewarm()
let session = DictationSession(
    hotkey: trigger, audio: audio, transcriber: transcriber, cleanup: cleanup,
    injectors: InjectorChain([
        (.axSelectedText, AXSelectedTextInjector(log: log)),
        (.paste, PasteInjector()),
        (.unicodeType, UnicodeTypeInjector()),
    ]),
    contextProvider: WorkspaceContextProvider(log: log),
    dictionaryStore: FileDictionaryStore(url: base.appending(path: "dictionary.txt")),
    settingsStore: MemorySettings(),
    clipboard: PasteboardClipboard(), undo: SystemUndo())

let states = await session.stateUpdates()
await session.start()
trigger.edges.yield(.pressed)    // start recording
// ...speak...
trigger.edges.yield(.released)   // transcribe, clean, type
for await state in states {      // wait for the dictation to finish
    print(state)
    if state == .idle { break }
}

await session.stopMonitoring()
cleanup.install(nil)
await llm.shutdown()             // llama.cpp's Metal teardown aborts if a context is alive at exit
```

The engine's tests build this exact set of adapters with a plain `import SottoEngine` (`Tests/SottoEngineTests/PublicSurfaceTests.swift`), so the snippet can't drift from the public API unnoticed.

`stateUpdates()` reports `recording`, `transcribing`, `cleaning`, `injecting`, `undone`, `degraded(reason)`, `error(reason)` and `idle`, which is everything a status indicator needs.

## The `sotto` CLI

A reference surface and smoke test, built from the same engine and only its public API (`Sources/SottoCLI/`).

Build it from a checkout:

```sh
swift build -c release --product sotto
.build/release/sotto --help
```

The binary lands at `.build/release/sotto` and loads `llama.framework` from the same directory. To put it on your `PATH`, symlink it (`ln -s "$PWD/.build/release/sotto" /usr/local/bin/sotto`), or copy `sotto` and `llama.framework` together into one directory.

```sh
sotto transcribe meeting.wav          # print the cleaned text of a WAV file
sotto dictate                         # record from the mic until you press Enter, then print
sotto dictate --inject                # type the result into the focused app instead
sotto transcribe memo.wav --raw       # skip the cleanup model; print the transcript as recognised
```

Text goes to stdout and status to stderr, so `sotto dictate | pbcopy` works. The CLI never downloads on its own: add `--download` the first time to fetch the models into `~/Library/Application Support/sotto-engine/Models/`. Exit codes follow sysexits (64 usage, 66 bad input, 69 model missing, 77 microphone denied; 1 when nothing was recognised). Full reference: [CLI.md](CLI.md).

## Relationship to the Sotto app

The Sotto app is built on this engine. The app adds onboarding, the menu bar and indicator, history, Insights and its voice profile; it doesn't get a better engine. Every improvement to transcription, cleanup, the dictionary, commands or injection lands here first.

## Stability

Versions are 0.x until app-aware formatting lands, then 1.0. Expect a few breaking minor releases before that. The protocols and `DictationSession.init` are frozen within a minor version; anything under `@_spi(Experimental)` can change at any time.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Commits need a DCO sign-off.

## Licence and attributions

Sotto Engine is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE).

It builds on, and the models it downloads are, the work of others:

| Component | Used as | Licence |
|---|---|---|
| [llama.cpp / ggml](https://github.com/ggml-org/llama.cpp) | linked binary framework | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Swift package (Parakeet inference) | Apache-2.0 |
| [Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), NVIDIA | speech model, downloaded at runtime | CC-BY-4.0 |
| [Qwen3-4B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507), Alibaba Cloud | cleanup model, downloaded at runtime | Apache-2.0 |

Model weights are never stored in this repository. If you ship the engine, credit Parakeet as CC-BY-4.0 requires.
