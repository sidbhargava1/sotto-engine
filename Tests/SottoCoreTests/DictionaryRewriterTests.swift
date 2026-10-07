// PLAN §6 Phase 4 must-do: deterministic heard-as rewrite before cleanup.
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class DictionaryRewriterTests: XCTestCase {
    static let dictionary = [
        "Sotto (soto)", "FleetView (fleet view)", "Qwen3 (quinn three, quen three)", "Quen (quen)",
        "llama.cpp (lama cpp)", "Parakeet", "Fleet (fleet)",
    ].map(DictionaryTerm.init)

    func test_rewritesTable() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("single word", "open soto now", "open Sotto now"),
            ("multi-word", "the fleet view beta", "the FleetView beta"),
            ("second variant of a term", "load quinn three", "load Qwen3"),
            ("case variants", "Fleet View and FLEET VIEW and Soto", "FleetView and FleetView and Sotto"),
            ("whitespace between words", "fleet \t view", "FleetView"),
            ("punctuation after", "fleet view, then soto.", "FleetView, then Sotto."),
            ("punctuation around", "(soto) \"fleet view\"? soto's", "(Sotto) \"FleetView\"? Sotto's"),
            ("partial word stays", "fleet viewer and sotos and isoto", "Fleet viewer and sotos and isoto"),
            ("punctuation inside a variant blocks it", "fleet, view", "Fleet, view"),
            ("longest wins over a shorter overlap", "quen three then quen", "Qwen3 then Quen"),
            ("multi-word beats its own first word", "fleet view fleet", "FleetView Fleet"),
            ("regex metacharacters are literal", "build lama cpp", "build llama.cpp"),
            ("term without variants is not a rule", "a parakeet", "a parakeet"),
            ("start and end of transcript", "soto", "Sotto"),
            ("unicode neighbours are word chars", "sotoé café soto", "sotoé café Sotto"),
        ]
        for c in cases {
            XCTAssertEqual(DictionaryRewriter.rewrite(c.input, terms: Self.dictionary), c.expected, c.name)
        }
    }

    func test_neverRescansAReplacement() {
        let terms = [DictionaryTerm("fleet view (fv)"), DictionaryTerm("FleetView (fleet view)")]
        XCTAssertEqual(DictionaryRewriter.rewrite("fv", terms: terms), "fleet view")
    }

    func test_emptyDictionaryAndEmptyTranscriptAreIdentity() {
        XCTAssertEqual(DictionaryRewriter.rewrite("fleet view, soto", terms: []), "fleet view, soto")
        XCTAssertEqual(DictionaryRewriter.rewrite("", terms: Self.dictionary), "")
    }

    func test_conflictingSpellingsResolveTheSameWhateverTheFileOrder() {
        let terms = [DictionaryTerm("Sotto (soto)"), DictionaryTerm("SOTTO (Soto)")]
        let forward = DictionaryRewriter.rewrite("soto", terms: terms)
        XCTAssertEqual(forward, DictionaryRewriter.rewrite("soto", terms: terms.reversed()))
        XCTAssertEqual(forward, "SOTTO")
    }

    func test_parsesHeardAsFromTheExistingLineFormat() {
        let cases: [(line: String, spelling: String, heardAs: [String])] = [
            ("Sotto (soto)", "Sotto", ["soto"]),
            ("Qwen3 (quinn three,  quen   three )", "Qwen3", ["quinn three", "quen three"]),
            ("Sotto(soto)", "Sotto", ["soto"]),
            ("Parakeet", "Parakeet", []),
            ("Foo ()", "Foo", []),
            ("Foo (a,,b)", "Foo", ["a", "b"]),
            ("(soto)", "(soto)", []),
            ("Foo (bar", "Foo (bar", []),
            ("Foo (bar) baz", "Foo (bar) baz", []),
            ("A (b (c))", "A (b (c))", []),
        ]
        for c in cases {
            let term = DictionaryTerm(c.line)
            XCTAssertEqual(term.spelling, c.spelling, c.line)
            XCTAssertEqual(term.heardAs, c.heardAs, c.line)
        }
    }
}

final class DictionaryRewriteSessionTests: SessionTestCase {
    func test_backendGetsRewrittenTextWhileCommandsMatchTheOriginal() async {
        // A heard-as variant equal to the command phrase proves matching ran before the rewrite.
        let dictionary = ["FleetView (fleet view)", "Scratchpad (scratch that)"].map(DictionaryTerm.init)
        let backend = FixtureBackend(steps: [.init("The FleetView beta.")])
        let transcriber = FixtureTranscriber([.text("the fleet view beta"), .text("scratch that")])
        let h = makeHarness(transcriber: transcriber, backend: backend, dictionary: dictionary)
        await h.session.start()
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)
        await h.hotkey.press(); await h.hotkey.release()
        await settle(h)

        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.rawTranscript), ["the FleetView beta"])
        XCTAssertEqual(requests.first?.dictionary, dictionary.map(\.text), "the prompt keeps the full lines as backstop")
        let undoCalls = await h.undo.callCount()
        XCTAssertEqual(undoCalls, 1)
    }

    func test_rawFallbackTypesTheRewrittenText() async {
        let backend = FixtureBackend(steps: [], ending: .fail(CleanupError.notReady))
        let h = makeHarness(transcriber: FixtureTranscriber([.text("ship soto today")]), backend: backend, dictionary: [DictionaryTerm("Sotto (soto)")])
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "ship Sotto today")
    }
}
