import XCTest
@testable import SottoCore

/// QA-engineer rows for the grammar and resolver (2026-10-10). Row numbers are the QA list's.
final class CommandGrammarQATests: XCTestCase {
    typealias T = CommandGrammarTests
    let cat = T.catalog()

    func k(_ s: String, _ c: CommandCatalog? = nil) -> CommandKeyResult {
        CommandRouter.routeCommandKey(s, catalog: c ?? cat)
    }
    func d(_ s: String, _ c: CommandCatalog? = nil) -> DictationKeyRouting {
        CommandRouter.routeDictationKey(s, catalog: c ?? cat, prefixEnabled: true)
    }
    func slackOpen() -> ResolvedCommand { .app(T.slack, state: .running, verb: .open) }
    func noApp(_ s: String) -> CommandFailure { .notFound(.app, spoken: s) }

    func test_rows1to8_punctuationFillerWake() {
        for s in ["Open Slack.", "OPEN   SLACK", "Sotto. Please open Slack, for me.",
                  "hey can you please open Slack up", "so to open Slack"] {
            XCTAssertEqual(k(s), .resolved(slackOpen()), s)
        }
        for s in ["open x-code", "open X Code!"] {
            XCTAssertEqual(k(s), .resolved(.app(T.xcode, state: .running, verb: .open)), s)
        }
        for s in ["please", "can you", "Sotto"] { XCTAssertEqual(k(s), .failed(.unrecognised), s) }
    }

    func test_rows9to14_prefixWindowAndTwoWordRule() {
        XCTAssertEqual(d("So to open Slack"), .command(slackOpen()))
        XCTAssertEqual(d("Sotto, please open Slack"), .command(slackOpen()))
        XCTAssertEqual(d("Sotto, could you please open Slack"), .dictation)
        XCTAssertEqual(d("Sotto open Slak."), .commandError(noApp("Slak")))
        XCTAssertEqual(d("soto open slak"), .commandError(noApp("slak")))
        XCTAssertEqual(d("Sotto open Slak app"), .commandError(noApp("Slak app")))
        XCTAssertEqual(d("Sotto open the Slak app"), .dictation)
        XCTAssertEqual(d("I said Sotto open Slack"), .dictation)
    }

    func test_rows15to18_wordLimits() {
        XCTAssertEqual(k("open the Slak app please"), .failed(noApp("the Slak app")))
        XCTAssertEqual(k("open one two three four"), .failed(noApp("one two three four")))
        XCTAssertEqual(k("open one two three four five"), .failed(.unrecognised))
        XCTAssertEqual(d("Sotto open one two"), .commandError(noApp("one two")))
        XCTAssertEqual(d("Sotto open one two three"), .dictation)
        // Trailing filler counts toward neither limit.
        XCTAssertEqual(k("open one two three four please"), .failed(noApp("one two three four")))
        XCTAssertEqual(d("Sotto open one two please"), .commandError(noApp("one two")))
        XCTAssertEqual(d("Sotto open one two for me"), .commandError(noApp("one two")))
    }

    func test_row19_exactBeatsPartMatch() {
        XCTAssertEqual(k("open Google Chrome"), .resolved(.app(T.chrome, state: .running, verb: .open)))
        let google = CatalogApp(name: "Google", id: "id.google")
        var c = cat
        c.apps.append(google)
        XCTAssertEqual(k("open google", c), .resolved(.app(google, state: .notRunning, verb: .open)))
    }

    func test_row20_21_states() {
        var c = cat
        c.frontmostAppID = T.safari.id
        XCTAssertEqual(k("switch to Safari", c), .resolved(.app(T.safari, state: .frontmost, verb: .switchTo)))
        XCTAssertEqual(k("open Mail"), .resolved(.app(T.mail, state: .notRunning, verb: .open)))
        XCTAssertEqual(k("hide Mail"), .failed(.notRunning(T.mail)))
        XCTAssertEqual(k("hide Slak"), .failed(noApp("Slak")))
    }

    func test_row22_namedItemsAndSwitch() {
        var c = cat
        let app = CatalogApp(name: "Standup", id: "id.standup")
        c.apps.append(app)
        XCTAssertEqual(k("open standup", c), .resolved(.openLink(T.standup)))
        XCTAssertEqual(k("switch to standup", c), .resolved(.app(app, state: .notRunning, verb: .switchTo)))
        XCTAssertEqual(k("go to standup", c), .resolved(.app(app, state: .notRunning, verb: .switchTo)))
        XCTAssertEqual(k("open folder standup", c), .failed(.notFound(.folder, spoken: "standup")))
        XCTAssertEqual(k("hide invoices"), .failed(noApp("invoices")))
        XCTAssertEqual(k("switch to invoices"), .failed(noApp("invoices")))
    }

    func test_row23_emptyCatalogue() {
        let empty = CommandCatalog(apps: [], runningAppIDs: [], frontmostAppID: nil, folders: [], links: [],
                                   shortcuts: [], shortcutsEnabled: true, shortcutsFolderName: "Sotto")
        XCTAssertEqual(k("open Slack", empty), .failed(noApp("Slack")))
        XCTAssertEqual(k("run x", empty), .failed(.notFound(.shortcut, spoken: "x")))
        XCTAssertEqual(k("hide Slack", empty), .failed(noApp("Slack")))
    }

    func test_row24_unicodeFolding() {
        func app(_ n: String, _ id: String) -> CatalogApp { CatalogApp(name: n, id: id) }
        let cafe = app("Café Notes", "id.cafe"), resume = app("Résumé", "id.resume")
        let nfd = app("Cafe\u{301} Desk", "id.desk"), emoji = app("🚀 Rocket", "id.rocket")
        let cjk = app("日本語", "id.cjk")
        var c = cat
        c.apps += [cafe, resume, nfd, emoji, cjk]
        func opens(_ s: String, _ a: CatalogApp) {
            XCTAssertEqual(k(s, c), .resolved(.app(a, state: .notRunning, verb: .open)), s)
        }
        opens("open cafe notes", cafe)
        opens("open CAFÉ NOTES", cafe)
        opens("open cafe\u{301} notes", cafe)   // NFD speech against NFC name
        opens("open resume", resume)
        opens("open Café Desk", nfd)            // NFC speech against NFD name
        opens("open rocket", emoji)
        opens("open 日本語", cjk)
    }

    func test_row24_extra_equalNamesAreAmbiguousDifferentIDs() {
        var c = cat
        c.apps.append(CatalogApp(name: "S-lack", id: "id.slack2"))
        XCTAssertEqual(k("open slack", c), .failed(.ambiguous(spoken: "slack", candidates: ["Slack", "S-lack"])))
        var folded = cat
        folded.apps += [CatalogApp(name: "Resume", id: "a"), CatalogApp(name: "Résumé", id: "b")]
        XCTAssertEqual(k("open resume", folded), .failed(.ambiguous(spoken: "resume", candidates: ["Resume", "Résumé"])))
    }

    func test_row25_pathologicalInputIsBoundedAndNoMatch() {
        let words = Array(repeating: "word", count: 5_000).joined(separator: " ")
        let huge = String(repeating: "a", count: 100_000)
        let openHuge = "open " + words
        let spaced = String(repeating: " ", count: 100_000) + "open slack"
        let start = Date()
        XCTAssertEqual(k(words), .failed(.unrecognised))
        XCTAssertEqual(k(huge), .failed(.unrecognised))
        XCTAssertEqual(k(openHuge), .failed(.unrecognised))
        XCTAssertEqual(k("open " + huge), .failed(.unrecognised))
        XCTAssertEqual(k(String(repeating: "please ", count: 5_000) + "open slack"), .failed(.unrecognised))
        XCTAssertEqual(d("Sotto " + words), .dictation)
        XCTAssertEqual(d("Sotto open " + words), .dictation)
        _ = k(spaced)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        for s in ["open", "open ...", "open !?, -", "Sotto open ."] { XCTAssertEqual(k(s), .failed(.unrecognised), s) }
    }
}
