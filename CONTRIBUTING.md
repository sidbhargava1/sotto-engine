# Contributing to Sotto Engine

Thanks for looking. Bug reports, fixes and new adapters are all welcome. This page covers how to build, the rules the code depends on, and what a pull request needs.

Sotto Engine has one maintainer. Response times vary from a day to a few weeks. A small, focused PR with a clear description gets reviewed fastest.

## Build and test

You need macOS 15 or later on Apple silicon and full Xcode 26, selected with `xcode-select`. Command Line Tools alone are not enough: SpeechAnalyzer needs the macOS 26 SDK. Everything builds on the host; there is no container setup.

```sh
scripts/build-llama.sh                # optional (~4 min, needs cmake): Vendor/llama.xcframework from the pinned llama.cpp tag;
                                      # without it, SwiftPM downloads the release's prebuilt one
                                      # (built after a first swift build? add SOTTO_LLAMA_LOCAL=1 to link it)
swift test --filter SottoCoreTests    # pure logic; no permissions, no devices, no models
swift test --filter SottoEngineTests  # adapter tests (AVFoundation, no devices)
swift test --filter SottoCLITests     # the CLI: parsing, exit codes, the built binary on silence and missing models
swift build                           # engine and the sotto CLI
```

Xcode doesn't pass your shell environment to SwiftPM, so if you build in Xcode, run `swift package purge-cache` once after `scripts/build-llama.sh` instead of setting `SOTTO_LLAMA_LOCAL`.

The SottoCore tests are the ones that matter most. They drive the whole dictation flow with fakes, so a change to `DictationSession`, injection policy, command parsing or the prompt should come with a test there.

To try a change end to end without speaking, run the CLI on a WAV:

```sh
swift run sotto transcribe path/to/clip.wav --raw
```

Drop `--raw` to include cleanup; the first run needs `--download` to fetch the 2.5 GB model. The CLI tests run a real transcription too when you point them at a speech clip and the models: `SOTTO_CLI_FIXTURE=clip.wav SOTTO_CLI_MODELS=<dir> swift test --filter CLIProcessTests`. CI has no weights, so that test skips there.

Two things that will bite you:

- **Accessibility grants are tied to the code signature.** An ad-hoc signed build loses its grant on every rebuild. Sign local builds that inject text with a stable identity, or test injection through the CLI from a terminal that already has the grant.
- **Free the llama context and model before the process exits.** llama.cpp's Metal teardown aborts if either is still alive, so every exit becomes a crash report.

## The rules

These aren't derivable from the code, and each one would come back as a bug if it were relaxed. PRs that break them will be asked to change, whatever else they do well.

1. **SottoCore never imports AppKit, AVFoundation or CoreML.** It holds the logic and the protocols. Anything that touches the system is an adapter in SottoEngine behind a protocol. That separation is what lets the whole flow run in tests with no microphone and no permissions.
2. **Injection never synthesises Return or Enter.** The engine types into whatever has focus, including shells, where a stray newline runs a command. In terminals and in Unicode typing, line breaks become a space; `InjectionText.sanitizeForTerminal` is the only code that strips them.
3. **Insert with `kAXSelectedTextAttribute`, never `kAXValueAttribute`.** `kAXValue` replaces the entire field and destroys whatever the user had already written. `kAXSelectedText` with an empty selection inserts at the caret.
4. **Voice commands are matched before cleanup, on the raw transcript.** The cleanup model treats "scratch that" as a false start and rewrites or deletes it, so matching after cleanup means matching mangled text.

A few more, from the same place:

- **Cleanup failure types the raw transcript, never nothing.** Only a speech-to-text failure may produce no output.
- **The prompt prefix must be byte-identical across apps.** Instructions and dictionary come first; the bundle ID and transcript go after the cache boundary, in the user turn. One stray byte that varies by app invalidates the KV cache on every switch.
- **Build realtime audio callbacks outside `@MainActor` code.** A closure that inherits main-actor isolation traps when AVFAudio calls it from its own thread.
- **The privacy promise is enforced in code.** No network call except the explicit model download, no telemetry, no transcripts on disk, and no transcript text in logs (counts and timings only). A PR that adds any of these won't be merged.

## Pull requests

- **One change per PR.** A bug fix and a refactor are two PRs.
- **Tests with the change.** Logic changes need SottoCore tests. Adapter changes need a test where one is possible, and otherwise a note on how you checked it by hand: which apps, which macOS version.
- **Run the commands above before you push.** CI (`.github/workflows/ci.yml`, one job on GitHub's macOS 15 runner with Xcode 26.3) runs `swift build`, `swift test` (all three test targets), a release build of the CLI and `sotto --help`. It has no model weights, microphone or permissions, so it can't check recognition quality, recording or injection into real apps; say how you checked those by hand.
- **Say why.** The description should explain what was wrong or missing and how you know the change fixes it. Link an issue if there is one.
- **Public API changes need a heads-up.** The protocols and `DictationSession.init` are frozen within a minor version. If your change touches them, open an issue first so we can agree on the shape. Experimental API goes under `@_spi(Experimental)`.
- **Docs in the same PR.** If behaviour changes, update the README or CLI.md alongside the code.
- **Keep comments short.** Explain why in a line or two; don't narrate what the code does.

Never commit model weights, audio of real people, or real transcripts. Test fixtures should be synthesised speech or clips you recorded yourself and are happy to publish.

## Sign your commits (DCO)

Every commit needs a `Signed-off-by` line certifying the [Developer Certificate of Origin](https://developercertificate.org/): that you wrote the change, or otherwise have the right to submit it under Apache-2.0.

```sh
git commit -s -m "Fix paste fallback when the clipboard is empty"
```

That adds `Signed-off-by: Your Name <you@example.com>` using your Git name and email. If you forgot, `git commit --amend -s` fixes the last commit and `git rebase --signoff main` fixes a branch. PRs with unsigned commits can't be merged.

There is no CLA. Your contribution stays yours, licensed under Apache-2.0.

## Reporting bugs

Include your macOS version, Mac model, which speech engine you used, and the target app if text landed in the wrong place or didn't land. Logs from `log show --info --predicate 'subsystem == "<your subsystem>"'` help and contain no transcript text: the subsystem is the `LogSubsystem` the host passed to the engine (`sotto-engine` if it passed `LogSubsystem.engine`).

Please don't attach recordings of anyone who hasn't agreed to it.
