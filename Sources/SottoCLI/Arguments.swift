// Hand-parsed (CLI.md): the engine has no swift-argument-parser dependency and the CLI
// isn't worth adding one to the public package for. Pure, so parsing and exit codes are unit-tested.
import Foundation

/// sysexits(3) codes, per CLI.md "Exit status".
enum ExitCode: Int32, Error, Sendable {
    case ok = 0
    case nothingRecognised = 1
    case usage = 64       // EX_USAGE
    case noInput = 66     // EX_NOINPUT
    case unavailable = 69 // EX_UNAVAILABLE
    case noPermission = 77 // EX_NOPERM
    case cancelled = 130  // 128 + SIGINT
}

enum CLICommand: Equatable, Sendable {
    case transcribe(URL)
    case dictate
}

enum CLIEngine: String, Equatable, Sendable {
    case parakeet, apple
}

struct Invocation: Equatable, Sendable {
    var command: CLICommand
    var raw = false
    var inject = false
    var engine = CLIEngine.parakeet
    var dictionary: URL?
    var models: URL
    var download = false
    var input: String?
    var quiet = false
}

enum ParseResult: Equatable, Sendable {
    case help
    case version
    case run(Invocation)
}

struct UsageError: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Arguments {
    static let version = "0.1.0"  // bump with the engine tag

    /// The engine's own directory, never a host app's: sharing one is opt-in through `--models`.
    static let defaultModels = URL.applicationSupportDirectory
        .appending(path: "sotto-engine/Models", directoryHint: .isDirectory)

    static let synopsis = """
        usage: sotto transcribe <file.wav> [--raw] [--inject] [options]
               sotto dictate [--raw] [--inject] [options]
               sotto --version
               sotto --help
        """

    static let usage = synopsis + """


        Runs the Sotto Engine once: speech-to-text, local cleanup, then output.
        The result goes to stdout; status and warnings go to stderr.

        commands:
          transcribe <file.wav>   transcribe a WAV file (cut at 60 s)
          dictate                 record from the microphone until Enter (at most 60 s)

        options:
          --raw                   skip the cleanup model; print the transcript as recognised
          --inject                type the result into the focused app instead of printing it
          --engine parakeet|apple speech-to-text engine (default parakeet; apple needs macOS 26)
          --dictionary <file>     personal dictionary, one name or term per line
          --models <dir>          model directory (default ~/Library/Application Support/sotto-engine/Models)
          --download              allow downloading missing models (the only network access)
          --input <uid>           dictate: record from this CoreAudio input device
          -q, --quiet             print nothing to stderr except errors
          --version               print the version
          -h, --help              print this help

        exit status: 0 ok, 1 nothing recognised, 64 usage, 66 bad input file,
                     69 model missing, 77 microphone denied, 130 cancelled
        """

    /// `cwd` and `home` resolve relative and `~` paths; injectable for tests.
    static func parse(_ args: [String], cwd: URL = URL.currentDirectory(), home: URL = URL.homeDirectory) throws(UsageError) -> ParseResult {
        var command: String?
        var positionals: [String] = []
        var raw = false, inject = false, download = false, quiet = false
        var engine = CLIEngine.parakeet
        var dictionary: String?, models: String?, input: String?
        var help = false, version = false
        var optionsEnded = false

        var i = 0
        func value(for flag: String, inline: String?) throws(UsageError) -> String {
            if inline == nil { i += 1 }
            guard let value = inline ?? (i < args.count ? args[i] : nil), !value.isEmpty else { throw UsageError("\(flag) needs a value") }
            return value
        }

        while i < args.count {
            let arg = args[i]
            if optionsEnded || !arg.hasPrefix("-") || arg == "-" {
                if command == nil { command = arg } else { positionals.append(arg) }
                i += 1
                continue
            }
            // --flag=value is accepted for the flags that take one.
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let flag = parts[0]
            let inline = parts.count == 2 ? parts[1] : nil
            let takesValue = ["--engine", "--dictionary", "--models", "--input"].contains(flag)
            if inline != nil, !takesValue { throw UsageError("\(flag) takes no value") }
            switch flag {
            case "--": optionsEnded = true
            case "-h", "--help": help = true
            case "--version": version = true
            case "--raw": raw = true
            case "--inject": inject = true
            case "--download": download = true
            case "-q", "--quiet": quiet = true
            case "--engine":
                let name = try value(for: flag, inline: inline)
                guard let parsed = CLIEngine(rawValue: name) else { throw UsageError("--engine must be parakeet or apple, not '\(name)'") }
                engine = parsed
            case "--dictionary": dictionary = try value(for: flag, inline: inline)
            case "--models": models = try value(for: flag, inline: inline)
            case "--input": input = try value(for: flag, inline: inline)
            default: throw UsageError("unknown option \(arg)")
            }
            i += 1
        }

        if help { return .help }
        if version { return .version }
        guard let command else { throw UsageError("missing command: transcribe or dictate") }

        let resolve = { (path: String) in resolvePath(path, cwd: cwd, home: home) }
        let cliCommand: CLICommand
        switch command {
        case "transcribe":
            guard let file = positionals.first else { throw UsageError("transcribe needs a WAV file") }
            guard positionals.count == 1 else { throw UsageError("unexpected argument '\(positionals[1])'") }
            if input != nil { throw UsageError("--input applies to dictate only") }
            cliCommand = .transcribe(resolve(file))
        case "dictate":
            if let extra = positionals.first { throw UsageError("unexpected argument '\(extra)'") }
            cliCommand = .dictate
        default:
            throw UsageError("unknown command '\(command)'")
        }

        return .run(Invocation(
            command: cliCommand, raw: raw, inject: inject, engine: engine,
            dictionary: dictionary.map(resolve),
            models: models.map { resolve($0) } ?? defaultModels,
            download: download, input: input, quiet: quiet
        ))
    }

    /// Expands a leading `~` too: a quoted `"~/Library/…"` reaches us unexpanded.
    static func resolvePath(_ path: String, cwd: URL, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))).standardizedFileURL }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return cwd.appending(path: path).standardizedFileURL
    }
}
