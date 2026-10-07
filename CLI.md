# sotto(1)

## Name

`sotto` - on-device dictation from the command line

## Synopsis

```
sotto transcribe <file.wav> [--raw] [--inject] [options]
sotto dictate [--raw] [--inject] [options]
sotto --version
sotto --help
```

## Description

`sotto` runs the Sotto Engine pipeline once and exits: speech-to-text, local cleanup, then output. It is the engine's reference surface and smoke test: it drives the same `DictationSession` a host app does, built only from the public API (`Sources/SottoCLI/`).

The result goes to standard output with no decoration. A newline follows it only when standard output is a terminal, so a piped result never carries a Return into whatever it is pasted into. When collecting several results into one file, add `; echo` after each run. Everything else (state changes, model download progress, warnings) goes to standard error, so the output is safe to pipe. Usage errors print the synopsis to standard error.

`sotto` makes no network calls unless you pass `--download`, and writes nothing to disk except the model files.

## Commands

### `transcribe <file.wav>`

Reads a WAV file, transcribes it, cleans it up and prints the result. The file must be WAV (RIFF, RF64 or BW64); any sample rate, channel count and PCM format is accepted, and audio is converted to 16 kHz mono before recognition. Recordings longer than 60 seconds are cut at 60 seconds, the same cap a live dictation has, with a warning.

Needs no permissions unless `--inject` is given.

### `dictate`

Records from the microphone until you press Enter (or standard input ends, so Ctrl-D works too), then transcribes, cleans up and prints the result. Recording also stops at 60 seconds, with a warning. Ctrl-C cancels without printing anything.

Needs Microphone permission for the terminal app that runs it. macOS asks the first time.

## Options

`--inject`
: Type the result into the app that has focus when recognition finishes, using the engine's normal chain (`InjectorChain` with `DefaultInjectionPolicy`): Accessibility insertion at the caret, then paste, then Unicode typing. Terminals start at Unicode typing, with line breaks turned into spaces. Text injected back into the app `sotto` was launched from gets spaces instead of line breaks too, whatever that app is (an editor's integrated terminal, for one). Nothing is printed to stdout. Return is never pressed.
: If the focused app has no text field with focus, the result is pasted and also left on the clipboard, with a warning.
: Every step of that chain needs Accessibility permission, the paste fallback included, since it posts a synthetic ⌘V. On launch, `sotto` calls `AXIsProcessTrustedWithOptions` with the prompt on, so macOS offers to open System Settings if permission is missing.
: macOS grants Accessibility to the terminal app running `sotto` (Terminal, iTerm, Ghostty), not to `sotto` itself. Once granted, every process started from that terminal can read and control other apps. Grant it knowingly, and revoke it in System Settings → Privacy & Security → Accessibility when you're done.
: Without permission, the result is copied to the clipboard and a warning is printed.

`--raw`
: Skip the cleanup model and output the transcript as recognised, with whitespace normalised and any `--dictionary` heard-as rewrites applied. The 2.5 GB cleanup model is not needed or loaded.

`--engine parakeet|apple`
: Speech-to-text engine. `parakeet` (default) is NVIDIA Parakeet TDT 0.6B v2 via FluidAudio. `apple` is SpeechAnalyzer (en-US) and needs macOS 26; its assets are managed by macOS, so `--models` doesn't apply to them, and `--download` asks macOS to install them.

`--dictionary <file>`
: A personal dictionary, one name or term per line (`#` starts a comment). Default: none. A file that can't be read is exit 66.

`--models <dir>`
: Where model files live: the cleanup model's GGUF, and Parakeet in a `parakeet-tdt-0.6b-v2/` folder inside it. Default: `~/Library/Application Support/sotto-engine/Models/`. A leading `~` is expanded even when quoted.
: If Parakeet isn't in `<dir>` but is in FluidAudio's own cache (`~/Library/Application Support/FluidAudio/Models/`, where the Sotto app and other FluidAudio apps keep it), `sotto` uses that copy read-only and says so on stderr. `--download` always fetches into `<dir>`.
: On a Mac that already has the Sotto app, point it at the app's cleanup model so nothing downloads twice: `--models ~/Library/Application\ Support/Sotto/Models`.

`--download`
: Allow downloading missing models, through `ModelStore.ensureDownloaded`. Without it, a missing model is an error (exit 69) and no network request is made. With it, a speech model that is present but fails to load (an interrupted download) is fetched again.

`--input <uid>`
: For `dictate` only: record from the input device with this CoreAudio UID instead of the system default. An unknown UID falls back to the default with a warning.

`-q`, `--quiet`
: Print nothing to stderr except errors.

## Voice commands

The CLI has no voice commands. Each run is a single dictation with nothing earlier to undo, so "scratch that" is treated as plain text and goes through cleanup like any other words (`DictationSession(voiceCommands: false)`).

## Degraded results

If recognition succeeds but cleanup fails, stalls (no first token within 1.5 s, or more than 1 s between tokens) or isn't loaded, `sotto` prints the raw transcript, warns on stderr and exits 0. Speech that was recognised is never dropped. Only a recognition failure produces no output.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Text was printed or injected, including a raw fallback. |
| 1 | Nothing was recognised: silence, noise, a speech-to-text failure, or no audio input. |
| 64 | Usage error: unknown command or flag, missing or extra argument, missing option value. |
| 66 | The input file or `--dictionary` file is missing or unreadable, or the input isn't a WAV. |
| 69 | A required model is missing and `--download` wasn't given, a download failed (checksum or network), the speech model won't load, or `--engine apple` before macOS 26. |
| 77 | Microphone permission denied (`dictate`). |
| 130 | Cancelled with Ctrl-C. |

Missing Accessibility with `--inject` is not an error: the text goes to the clipboard and the exit code is 0.

## Files

`~/Library/Application Support/sotto-engine/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`
: The cleanup model, 2,497,281,120 bytes, sha256 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`. Downloads into a `.partial` file and is renamed only after the checksum matches. A download interrupted with Ctrl-C resumes on the next `--download`.

`~/Library/Application Support/sotto-engine/Models/parakeet-tdt-0.6b-v2/`
: The Parakeet Core ML model, about 450 MB, from [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml).

Logs go to the unified log under the subsystem `sotto-engine`, with counts and timings only: `log show --info --predicate 'subsystem == "sotto-engine"'`.

## Performance

On an Apple silicon Mac with the models on disk, a 15-second clip takes about 2.5 seconds end to end: about 1.6 s loading both models, under 0.1 s recognising, and under a second of cleanup. The first run of a newly built binary takes about 30 seconds longer while macOS compiles the Core ML and Metal code for it; later runs don't pay that.

## Examples

Print a cleaned transcript of a voice memo:

```sh
sotto transcribe ~/Desktop/memo.wav
```

First run, allowing the model download:

```sh
sotto transcribe memo.wav --download
```

Dictate a commit message:

```sh
git commit -m "$(sotto dictate)"
```

Type the result at the caret of the focused app. Run from a terminal, that's the terminal itself, since Enter stops the recording there. From a launcher or hotkey tool, give `sotto` a standard input that stays open until you want to stop: end of input stops the recording, so `< /dev/null` stops it at once.

```sh
sotto dictate --inject
```

Compare cleanup against the raw transcript:

```sh
diff <(sotto transcribe take1.wav --raw) <(sotto transcribe take1.wav)
```

Use your own vocabulary and Apple's recogniser:

```sh
sotto dictate --engine apple --dictionary ~/.config/sotto/words.txt
```

## See also

[README.md](README.md) for the library, [CONTRIBUTING.md](CONTRIBUTING.md) for building from source.
