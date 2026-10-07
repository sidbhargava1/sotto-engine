// CLI.md synopsis and options as pure parsing, plus the exit-code table read off session states.
// @testable only reaches the CLI's own parsing; the CLI itself uses the engine's public API.
import Foundation
import SottoCore
@testable import SottoCLI
import XCTest

final class ArgumentsTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/work", isDirectory: true)
    private let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)

    private func parse(_ args: String...) throws -> ParseResult {
        try Arguments.parse(args, cwd: cwd, home: home)
    }

    private func invocation(_ args: String...) throws -> Invocation {
        guard case .run(let inv) = try Arguments.parse(args, cwd: cwd, home: home) else {
            XCTFail("expected a run for \(args)")
            throw UsageError("not a run")
        }
        return inv
    }

    private func assertUsage(_ args: String..., contains fragment: String, line: UInt = #line) {
        XCTAssertThrowsError(try Arguments.parse(args, cwd: cwd, home: home), line: line) { error in
            XCTAssertTrue("\(error)".contains(fragment), "\(error)", line: line)
        }
    }

    func test_transcribeDefaults() throws {
        let inv = try invocation("transcribe", "memo.wav")
        XCTAssertEqual(inv.command, .transcribe(URL(fileURLWithPath: "/work/memo.wav")))
        XCTAssertEqual(inv.engine, .parakeet)
        XCTAssertFalse(inv.raw || inv.inject || inv.download || inv.quiet)
        XCTAssertNil(inv.dictionary)
        XCTAssertNil(inv.input)
        XCTAssertEqual(inv.models, Arguments.defaultModels)
    }

    /// The engine's own directory, never a host app's.
    func test_defaultModelsIsTheEnginesOwnDirectory() {
        let path = Arguments.defaultModels.path
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/sotto-engine/Models"), path)
    }

    func test_everyFlagBeforeOrAfterTheFile() throws {
        let inv = try invocation(
            "transcribe", "--raw", "memo.wav", "--inject", "--engine", "apple", "--dictionary", "words.txt",
            "--models", "/m", "--download", "-q"
        )
        XCTAssertEqual(inv.command, .transcribe(URL(fileURLWithPath: "/work/memo.wav")))
        XCTAssertTrue(inv.raw && inv.inject && inv.download && inv.quiet)
        XCTAssertEqual(inv.engine, .apple)
        XCTAssertEqual(inv.dictionary, URL(fileURLWithPath: "/work/words.txt"))
        XCTAssertEqual(inv.models, URL(fileURLWithPath: "/m"))
    }

    func test_inlineValuesAndLongQuiet() throws {
        let inv = try invocation("dictate", "--engine=apple", "--input=BuiltInMic", "--models=/m", "--quiet")
        XCTAssertEqual(inv.command, .dictate)
        XCTAssertEqual(inv.engine, .apple)
        XCTAssertEqual(inv.input, "BuiltInMic")
        XCTAssertEqual(inv.models, URL(fileURLWithPath: "/m"))
        XCTAssertTrue(inv.quiet)
    }

    /// A quoted "~/…" reaches the process unexpanded.
    func test_tildeAndRelativePathsResolve() throws {
        let inv = try invocation("transcribe", "../a.wav", "--models", "~/Library/Application Support/Host App/Models")
        XCTAssertEqual(inv.command, .transcribe(URL(fileURLWithPath: "/a.wav")))
        XCTAssertEqual(inv.models.path, "/home/someone/Library/Application Support/Host App/Models")
    }

    func test_doubleDashEndsOptions() throws {
        let inv = try invocation("transcribe", "--", "-odd.wav")
        XCTAssertEqual(inv.command, .transcribe(URL(fileURLWithPath: "/work/-odd.wav")))
    }

    func test_helpAndVersionWinOverEverythingElse() throws {
        XCTAssertEqual(try parse("--help"), .help)
        XCTAssertEqual(try parse("-h"), .help)
        XCTAssertEqual(try parse("transcribe", "--help"), .help)
        assertUsage("--frob", "--help", contains: "unknown option")  // parsing stops at the first bad flag
        XCTAssertEqual(try parse("--version"), .version)
        XCTAssertEqual(try parse("--version", "--help"), .help)
    }

    func test_usageErrors() {
        assertUsage(contains: "missing command")
        assertUsage("frob", contains: "unknown command")
        assertUsage("transcribe", contains: "needs a WAV file")
        assertUsage("transcribe", "a.wav", "b.wav", contains: "unexpected argument")
        assertUsage("dictate", "a.wav", contains: "unexpected argument")
        assertUsage("transcribe", "a.wav", "--frob", contains: "unknown option --frob")
        assertUsage("transcribe", "a.wav", "--engine", contains: "--engine needs a value")
        assertUsage("transcribe", "a.wav", "--engine", "whisper", contains: "parakeet or apple")
        assertUsage("transcribe", "a.wav", "--models", contains: "--models needs a value")
        assertUsage("transcribe", "a.wav", "--input", "x", contains: "dictate only")
        assertUsage("dictate", "--input=", contains: "--input needs a value")
        assertUsage("transcribe", "a.wav", "--models", "", contains: "--models needs a value")
        assertUsage("dictate", "--raw=yes", contains: "takes no value")
        assertUsage("dictate", "-qv", contains: "unknown option -qv")
    }

    func test_wavHeader() {
        func header(_ riff: String, _ wave: String) -> Data { Data((riff + "\0\0\0\0" + wave).utf8) }
        XCTAssertTrue(WAV.isWAV(header: header("RIFF", "WAVE")))
        XCTAssertTrue(WAV.isWAV(header: header("RF64", "WAVE")))
        XCTAssertTrue(WAV.isWAV(header: header("BW64", "WAVE")))
        XCTAssertFalse(WAV.isWAV(header: header("RIFF", "AVI ")))
        XCTAssertFalse(WAV.isWAV(header: header("FORM", "AIFF")))
        XCTAssertFalse(WAV.isWAV(header: Data("RIFF".utf8)))
        XCTAssertFalse(WAV.isWAV(header: Data()))
    }
}
