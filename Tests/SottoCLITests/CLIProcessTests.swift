// The built `sotto` binary end to end: real exit codes, and stdout carrying only the result.
// Nothing here downloads, records or types. With no weights (CI) every transcribe stops at 69;
// with Parakeet in FluidAudio's cache, the silence clips run through the engine and exit 1.
import AVFoundation
import SottoCore
import SottoEngine
import XCTest

final class CLIProcessTests: XCTestCase {
    struct Run {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "sotto-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// SwiftPM builds the executable beside the test bundle.
    private func binary() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "sotto")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            struct Missing: Error {}
            XCTFail("no sotto binary at \(url.path)")  // swift test builds it with the test target
            throw Missing()
        }
        return url
    }

    private func run(_ args: [String]) throws -> Run {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(code: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    /// Digital silence: what a mic delivers with nothing said.
    private func silentWAV(seconds: Double, rate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = scratch.appending(path: "silence-\(Int(rate))-\(channels).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
        return url
    }

    private var emptyModels: URL { scratch.appending(path: "Models", directoryHint: .isDirectory) }

    func test_helpAndVersionGoToStdout() throws {
        let help = try run(["--help"])
        XCTAssertEqual(help.code, 0)
        XCTAssertTrue(help.stdout.hasPrefix("usage: sotto transcribe"))
        XCTAssertEqual(help.stderr, "")
        let version = try run(["--version"])
        XCTAssertEqual(version.code, 0)
        XCTAssertTrue(version.stdout.hasPrefix("sotto "))
    }

    func test_usageErrorIsSixtyFourOnStderrOnly() throws {
        for args in [[], ["frob"], ["transcribe"], ["dictate", "--frob"]] {
            let result = try run(args)
            XCTAssertEqual(result.code, 64, "\(args)")
            XCTAssertEqual(result.stdout, "", "\(args)")
            XCTAssertTrue(result.stderr.contains("usage: sotto"), "\(args)")
        }
    }

    func test_badInputFileIsSixtySix() throws {
        let missing = try run(["transcribe", scratch.appending(path: "nope.wav").path])
        XCTAssertEqual(missing.code, 66)
        let text = scratch.appending(path: "notes.wav")
        try "not audio".write(to: text, atomically: true, encoding: .utf8)
        let notWAV = try run(["transcribe", text.path])
        XCTAssertEqual(notWAV.code, 66)
        XCTAssertTrue(notWAV.stderr.contains("not a WAV"))
        let dictionary = try run(["transcribe", try silentWAV(seconds: 1).path, "--dictionary", scratch.appending(path: "words.txt").path])
        XCTAssertEqual(dictionary.code, 66)
        XCTAssertEqual(missing.stdout + notWAV.stdout + dictionary.stdout, "")
    }

    /// No --download: a missing model is 69 and nothing is fetched (the directory stays empty).
    func test_missingCleanupModelIsSixtyNineAndFetchesNothing() throws {
        try FileManager.default.createDirectory(at: emptyModels, withIntermediateDirectories: true)
        let result = try run(["transcribe", try silentWAV(seconds: 1).path, "--models", emptyModels.path])
        XCTAssertEqual(result.code, 69)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("--download"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: emptyModels.path), [])
    }

    /// Silence at any rate and channel count: converted, recognised as nothing, exit 1. Without
    /// Parakeet anywhere (CI), it stops at 69 before loading anything.
    func test_silenceIsNothingRecognised() async throws {
        let parakeet = await ParakeetModelStore(root: nil).availability(for: ParakeetModelStore.id) == .ready
        for wav in [try silentWAV(seconds: 2), try silentWAV(seconds: 2, rate: 44_100, channels: 2)] {
            let result = try run(["transcribe", wav.path, "--raw", "--models", emptyModels.path])
            XCTAssertEqual(result.code, parakeet ? 1 : 69, result.stderr)
            XCTAssertEqual(result.stdout, "")
        }
        let quiet = try run(["transcribe", try silentWAV(seconds: 1).path, "--raw", "-q", "--models", emptyModels.path])
        XCTAssertEqual(quiet.stderr.split(separator: "\n").count, parakeet ? 1 : 2, "-q leaves only errors: \(quiet.stderr)")
    }

    /// Manual, with weights: SOTTO_CLI_FIXTURE=<speech wav> SOTTO_CLI_MODELS=<dir> swift test --filter CLIProcessTests
    func test_fixtureWithRealModels() throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["SOTTO_CLI_FIXTURE"], let models = env["SOTTO_CLI_MODELS"] else {
            throw XCTSkip("set SOTTO_CLI_FIXTURE and SOTTO_CLI_MODELS to run a real transcription")
        }
        let raw = try run(["transcribe", fixture, "--raw", "--models", models])
        XCTAssertEqual(raw.code, 0, raw.stderr)
        XCTAssertFalse(raw.stdout.isEmpty)
        XCTAssertFalse(raw.stdout.hasSuffix("\n"), "piped output carries no trailing newline")
        let cleaned = try run(["transcribe", fixture, "--models", models])
        XCTAssertEqual(cleaned.code, 0, cleaned.stderr)
        XCTAssertFalse(cleaned.stdout.isEmpty)
        XCTAssertFalse(cleaned.stderr.contains("warning"), cleaned.stderr)
    }
}
