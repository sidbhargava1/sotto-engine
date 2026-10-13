import XCTest
@testable import SottoCore

/// Spec §12: the grammar table, then focused rules. No system calls anywhere.
final class CommandGrammarTests: XCTestCase {
    static let slack = CatalogApp(name: "Slack", id: "id.slack")
    static let xcode = CatalogApp(name: "Xcode", id: "id.xcode")
    static let safari = CatalogApp(name: "Safari", id: "id.safari")
    static let chrome = CatalogApp(name: "Google Chrome", id: "id.chrome")
    static let drive = CatalogApp(name: "Google Drive", id: "id.drive")
    static let mail = CatalogApp(name: "Mail", id: "id.mail")
    static let invoices = CatalogItem(spokenName: "invoices", target: "opaque-folder")
    static let standup = CatalogItem(spokenName: "standup", target: "opaque-link")

    /// Slack, Xcode, Safari, Chrome and Drive are running; Mail is not.
    static func catalog(shortcuts: Bool = true) -> CommandCatalog {
        CommandCatalog(
            apps: [slack, xcode, safari, chrome, drive, mail],
            runningAppIDs: [slack.id, xcode.id, safari.id, chrome.id, drive.id],
            frontmostAppID: nil,
            folders: [invoices], links: [standup],
            shortcuts: [CatalogShortcut(name: "Weekly update")],
            shortcutsEnabled: shortcuts, shortcutsFolderName: "Sotto")
    }

    enum Expect {
        case open(CatalogApp, CommandAppState), switchTo(CatalogApp, CommandAppState)
        case hide(CatalogApp)
        case folder, link, shortcut(askFirst: Bool)
        case failed(CommandFailure)
        case dictation, scratchThat
    }

    struct Row {
        let n: Int
        let dictationKey: Bool
        let heard: String
        let expect: Expect
        var shortcutsOn = true
        var prefixOn = true
    }

    static let rows: [Row] = [
        Row(n: 1, dictationKey: false, heard: "open Slack", expect: .open(slack, .running)),
        Row(n: 2, dictationKey: false, heard: "Sotto, open Slack", expect: .open(slack, .running)),
        Row(n: 3, dictationKey: false, heard: "can you open slack please", expect: .open(slack, .running)),
        Row(n: 4, dictationKey: false, heard: "launch x code", expect: .open(xcode, .running)),
        Row(n: 5, dictationKey: false, heard: "switch to Safari", expect: .switchTo(safari, .running)),
        Row(n: 6, dictationKey: false, heard: "go to Mail", expect: .switchTo(mail, .notRunning)),
        Row(n: 7, dictationKey: false, heard: "hide Safari", expect: .hide(safari)),
        Row(n: 8, dictationKey: false, heard: "hide Mail", expect: .failed(.notRunning(mail))),
        Row(n: 9, dictationKey: false, heard: "hide", expect: .failed(.unrecognised)),
        Row(n: 10, dictationKey: false, heard: "open this app", expect: .failed(.unrecognised)),
        Row(n: 11, dictationKey: false, heard: "open chrome", expect: .open(chrome, .running)),
        Row(n: 12, dictationKey: false, heard: "open google",
            expect: .failed(.ambiguous(spoken: "google", candidates: ["Google Chrome", "Google Drive"]))),
        Row(n: 13, dictationKey: false, heard: "open invoices", expect: .folder),
        Row(n: 14, dictationKey: false, heard: "open folder invoices", expect: .folder),
        Row(n: 15, dictationKey: false, heard: "open link standup", expect: .link),
        Row(n: 16, dictationKey: false, heard: "open link invoices",
            expect: .failed(.notFound(.link, spoken: "invoices"))),
        Row(n: 17, dictationKey: false, heard: "run weekly update", expect: .shortcut(askFirst: true)),
        Row(n: 18, dictationKey: false, heard: "run shortcut weekly update", expect: .shortcut(askFirst: true)),
        Row(n: 19, dictationKey: false, heard: "open weekly update",
            expect: .failed(.notFound(.app, spoken: "weekly update"))),
        Row(n: 20, dictationKey: false, heard: "run backup", expect: .failed(.notFound(.shortcut, spoken: "backup"))),
        Row(n: 21, dictationKey: false, heard: "run weekly update", expect: .failed(.shortcutsOff), shortcutsOn: false),
        Row(n: 22, dictationKey: false, heard: "open slak", expect: .failed(.notFound(.app, spoken: "slak"))),
        Row(n: 23, dictationKey: false, heard: "open the thing I was looking at yesterday", expect: .failed(.unrecognised)),
        Row(n: 24, dictationKey: false, heard: "quit Slack", expect: .failed(.unrecognised)),
        Row(n: 25, dictationKey: false, heard: "send the report to Maria", expect: .failed(.unrecognised)),
        Row(n: 26, dictationKey: false, heard: "scratch that", expect: .failed(.unrecognised)),
        // Row 27 is test_row27: it goes through DictionaryRewriter.
        Row(n: 28, dictationKey: true, heard: "Sotto, open Slack", expect: .open(slack, .running)),
        Row(n: 29, dictationKey: true, heard: "soto open slack", expect: .open(slack, .running)),
        Row(n: 30, dictationKey: true, heard: "Sotto open Slak", expect: .failed(.notFound(.app, spoken: "Slak"))),
        Row(n: 31, dictationKey: true, heard: "Sotto open source release notes are ready", expect: .dictation),
        Row(n: 32, dictationKey: true, heard: "Sotto", expect: .dictation),
        Row(n: 33, dictationKey: true, heard: "I told Sotto to open Slack", expect: .dictation),
        Row(n: 34, dictationKey: true, heard: "Sotto what time is it", expect: .dictation),
        Row(n: 35, dictationKey: true, heard: "scratch that", expect: .scratchThat),
        Row(n: 36, dictationKey: true, heard: "open Slack", expect: .dictation),
        Row(n: 37, dictationKey: true, heard: "Sotto, open Slack", expect: .dictation, prefixOn: false),
    ]

    func test_table() {
        for row in Self.rows {
            check(row.n, row.dictationKey, row.heard, row.expect,
                  Self.catalog(shortcuts: row.shortcutsOn), prefixOn: row.prefixOn)
        }
    }

    /// Row 27: the host runs the heard-as rewrite first; the router never sees "fleet view".
    func test_row27_dictionaryAliasResolvesInstalledApp() {
        let fleet = CatalogApp(name: "FleetView", id: "id.fleet")
        var catalog = Self.catalog()
        catalog.apps.append(fleet)
        let rewritten = DictionaryRewriter.rewrite("open fleet view", terms: [DictionaryTerm("FleetView (fleet view)")])
        XCTAssertEqual(rewritten, "open FleetView")
        check(27, false, rewritten, .open(fleet, .notRunning), catalog, prefixOn: true)
    }

    private func check(_ n: Int, _ dictationKey: Bool, _ heard: String, _ expect: Expect,
                       _ catalog: CommandCatalog, prefixOn: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let msg = "row \(n): \(heard)"
        var resolved: ResolvedCommand?
        var failure: CommandFailure?
        var plain: DictationKeyRouting?
        if dictationKey {
            switch CommandRouter.routeDictationKey(heard, catalog: catalog, prefixEnabled: prefixOn) {
            case .command(let c): resolved = c
            case .commandError(let f): failure = f
            case .dictation: plain = .dictation
            case .scratchThat: plain = .scratchThat
            }
        } else {
            switch CommandRouter.routeCommandKey(heard, catalog: catalog) {
            case .resolved(let c): resolved = c
            case .failed(let f): failure = f
            }
        }
        switch expect {
        case .open(let app, let state):
            XCTAssertEqual(resolved, .open(app, state: state), msg, file: file, line: line)
        case .switchTo(let app, let state):
            XCTAssertEqual(resolved, .switchTo(app, state: state), msg, file: file, line: line)
        case .hide(let app): XCTAssertEqual(resolved, .hide(app), msg, file: file, line: line)
        case .folder: XCTAssertEqual(resolved, .openFolder(Self.invoices), msg, file: file, line: line)
        case .link: XCTAssertEqual(resolved, .openLink(Self.standup), msg, file: file, line: line)
        case .shortcut(let ask):
            XCTAssertEqual(resolved, .runShortcut(CatalogShortcut(name: "Weekly update", askFirst: ask)), msg, file: file, line: line)
        case .failed(let f): XCTAssertEqual(failure, f, msg, file: file, line: line)
        case .dictation: XCTAssertEqual(plain, .dictation, msg, file: file, line: line)
        case .scratchThat: XCTAssertEqual(plain, .scratchThat, msg, file: file, line: line)
        }
    }

    // MARK: normalisation and filler

    func test_normalisation() {
        for heard in ["OPEN   slack", "Open, Slack.", "  open slack!  ", "open SLACK"] {
            XCTAssertEqual(CommandGrammar.parseCommandKey(heard)?.verb, .open, heard)
            XCTAssertEqual(CommandGrammar.parseCommandKey(heard)?.target.lowercased(), "slack", heard)
        }
    }

    func test_fillerLeadingAndTrailing() {
        for heard in ["please open slack", "hey open slack", "could you please open slack",
                      "open slack for me", "open slack up", "open slack for me please", "Sotto, hey open slack up"] {
            XCTAssertEqual(CommandGrammar.parseCommandKey(heard)?.target, "slack", heard)
        }
    }

    func test_verbForms() {
        XCTAssertEqual(CommandGrammar.parseCommandKey("launch slack")?.verb, .open)
        XCTAssertEqual(CommandGrammar.parseCommandKey("go to slack")?.verb, .switchTo)
        XCTAssertEqual(CommandGrammar.parseCommandKey("run shortcut weekly update")?.target, "weekly update")
        XCTAssertEqual(CommandGrammar.parseCommandKey("open folder invoices")?.forcedKind, .folder)
        XCTAssertEqual(CommandGrammar.parseCommandKey("open link standup")?.forcedKind, .link)
    }

    func test_closedVerbList() {
        for heard in ["quit slack", "close slack", "send slack", "switch slack", "go slack", "show slack", ""] {
            XCTAssertNil(CommandGrammar.parseCommandKey(heard), heard)
        }
    }

    // MARK: deictics, no object, length

    func test_deicticsAndNoObjectAreGenericNoMatch() {
        for heard in ["open this", "open this app", "open that", "open it", "hide the window", "switch to it",
                      "open", "open folder", "run shortcut", "hide please", "go to"] {
            XCTAssertEqual(CommandRouter.routeCommandKey(heard, catalog: Self.catalog()),
                           .failed(.unrecognised), heard)
        }
    }

    func test_fourWordTargetIsNamedFiveIsGeneric() {
        XCTAssertEqual(CommandRouter.routeCommandKey("open a b c d", catalog: Self.catalog()),
                       .failed(.notFound(.app, spoken: "a b c d")))
        XCTAssertEqual(CommandRouter.routeCommandKey("open a b c d e", catalog: Self.catalog()), .failed(.unrecognised))
    }

    // MARK: dictation-key prefix

    func test_d5_twoWordTargetErrors_threeWordsType() {
        let c = Self.catalog()
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto open the red one", catalog: c, prefixEnabled: true), .dictation)
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto open red one", catalog: c, prefixEnabled: true),
                       .commandError(.notFound(.app, spoken: "red one")))
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto open slak", catalog: c, prefixEnabled: true),
                       .commandError(.notFound(.app, spoken: "slak")))
    }

    func test_wakeVariantsAndOtto() {
        let c = Self.catalog()
        for wake in ["sotto", "Soto,", "so to", "So to,"] {
            XCTAssertEqual(CommandRouter.routeDictationKey("\(wake) open slack", catalog: c, prefixEnabled: true),
                           .command(.open(Self.slack, state: .running)), wake)
        }
        XCTAssertEqual(CommandRouter.routeDictationKey("otto open slack", catalog: c, prefixEnabled: true), .dictation)
    }

    func test_verbWithinThreeWordsOfWake() {
        let c = Self.catalog()
        let slack = DictationKeyRouting.command(.open(Self.slack, state: .running))
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto can you open slack", catalog: c, prefixEnabled: true), slack)
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto could you please open slack", catalog: c, prefixEnabled: true), .dictation)
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto just open slack", catalog: c, prefixEnabled: true), .dictation)
    }

    func test_prefixDeicticAndNoObjectAreDictation() {
        let c = Self.catalog()
        for heard in ["Sotto open this app", "Sotto open", "Sotto hide it"] {
            XCTAssertEqual(CommandRouter.routeDictationKey(heard, catalog: c, prefixEnabled: true), .dictation, heard)
        }
    }

    func test_scratchThatWinsOnDictationKeyEvenWithPrefixOff() {
        XCTAssertEqual(CommandRouter.routeDictationKey("scratch that", catalog: Self.catalog(), prefixEnabled: false), .scratchThat)
    }

    // MARK: resolution

    func test_normalisedNameMatching() {
        let vsc = CatalogApp(name: "Visual-Studio Code", id: "id.vsc")
        var c = Self.catalog()
        c.apps.append(vsc)
        XCTAssertEqual(CommandRouter.routeCommandKey("open x code", catalog: c),
                       .resolved(.open(Self.xcode, state: .running)))
        XCTAssertEqual(CommandRouter.routeCommandKey("open visual studio", catalog: c),
                       .resolved(.open(vsc, state: .notRunning)))
    }

    func test_exactBeatsPartial() {
        let google = CatalogApp(name: "Google", id: "id.google")
        var c = Self.catalog()
        c.apps.append(google)
        XCTAssertEqual(CommandRouter.routeCommandKey("open google", catalog: c),
                       .resolved(.open(google, state: .notRunning)))
    }

    func test_ambiguityNeverGuesses() {
        XCTAssertEqual(CommandRouter.routeCommandKey("switch to google", catalog: Self.catalog()),
                       .failed(.ambiguous(spoken: "google", candidates: ["Google Chrome", "Google Drive"])))
    }

    func test_partOfNameMustBeWholeWords() {
        XCTAssertEqual(CommandRouter.routeCommandKey("open chro", catalog: Self.catalog()),
                       .failed(.notFound(.app, spoken: "chro")))
    }

    func test_namedItemBeatsSameNamedApp() {
        let app = CatalogApp(name: "Invoices", id: "id.invoices")
        var c = Self.catalog()
        c.apps.append(app)
        XCTAssertEqual(CommandRouter.routeCommandKey("open invoices", catalog: c), .resolved(.openFolder(Self.invoices)))
        XCTAssertEqual(CommandRouter.routeCommandKey("switch to invoices", catalog: c),
                       .resolved(.switchTo(app, state: .notRunning)))
    }

    func test_folderAndLinkSameNameIsAmbiguousUnlessForced() {
        var c = Self.catalog()
        c.links.append(CatalogItem(spokenName: "Invoices", target: "https://example.com"))
        XCTAssertEqual(CommandRouter.routeCommandKey("open invoices", catalog: c),
                       .failed(.ambiguous(spoken: "invoices", candidates: ["invoices", "Invoices"])))
        XCTAssertEqual(CommandRouter.routeCommandKey("open folder invoices", catalog: c), .resolved(.openFolder(Self.invoices)))
    }

    func test_kindsNeverCross() {
        let c = Self.catalog()
        XCTAssertEqual(CommandRouter.routeCommandKey("run slack", catalog: c), .failed(.notFound(.shortcut, spoken: "slack")))
        XCTAssertEqual(CommandRouter.routeCommandKey("open weekly update", catalog: c),
                       .failed(.notFound(.app, spoken: "weekly update")))
        XCTAssertEqual(CommandRouter.routeCommandKey("hide invoices", catalog: c), .failed(.notFound(.app, spoken: "invoices")))
        XCTAssertEqual(CommandRouter.routeCommandKey("open link invoices", catalog: c),
                       .failed(.notFound(.link, spoken: "invoices")))
    }

    func test_shortcutsOffWinsOverNotFound() {
        XCTAssertEqual(CommandRouter.routeCommandKey("run backup", catalog: Self.catalog(shortcuts: false)), .failed(.shortcutsOff))
    }

    func test_shortcutAskFirstIsCarriedPerName() {
        var c = Self.catalog()
        c.shortcuts = [CatalogShortcut(name: "Weekly update", askFirst: false), CatalogShortcut(name: "Deploy")]
        XCTAssertEqual(CommandRouter.routeCommandKey("run weekly update", catalog: c),
                       .resolved(.runShortcut(CatalogShortcut(name: "Weekly update", askFirst: false))))
        XCTAssertEqual(CommandRouter.routeCommandKey("run deploy", catalog: c),
                       .resolved(.runShortcut(CatalogShortcut(name: "Deploy", askFirst: true))))
    }

    func test_appStates() {
        var c = Self.catalog()
        c.frontmostAppID = Self.safari.id
        XCTAssertEqual(CommandRouter.routeCommandKey("open safari", catalog: c),
                       .resolved(.open(Self.safari, state: .frontmost)))
        XCTAssertEqual(CommandRouter.routeCommandKey("switch to slack", catalog: c),
                       .resolved(.switchTo(Self.slack, state: .running)))
        XCTAssertEqual(CommandRouter.routeCommandKey("open mail", catalog: c),
                       .resolved(.open(Self.mail, state: .notRunning)))
        XCTAssertEqual(CommandRouter.routeCommandKey("hide safari", catalog: c), .resolved(.hide(Self.safari)))
    }

    func test_duplicateAppIDsAreNotAmbiguous() {
        var c = Self.catalog()
        c.apps.append(Self.slack)
        XCTAssertEqual(CommandRouter.routeCommandKey("open slack", catalog: c),
                       .resolved(.open(Self.slack, state: .running)))
    }

    // MARK: review follow-ups

    func test_truncatedInputIsNeverScanned() {
        let c = Self.catalog()
        let padded = String(repeating: "please ", count: 30) + "open slack and tell everyone"
        XCTAssertEqual(CommandRouter.routeCommandKey(padded, catalog: c), .failed(.unrecognised))
        XCTAssertEqual(CommandRouter.routeDictationKey(padded, catalog: c, prefixEnabled: true), .dictation)
        let sotto = "Sotto " + padded
        XCTAssertEqual(CommandRouter.routeDictationKey(sotto, catalog: c, prefixEnabled: true), .dictation)
        // 32 words is allowed, 33 is not.
        let at32 = "open slack " + Array(repeating: "x", count: 30).joined(separator: " ")
        XCTAssertNil(CommandGrammar.words(at32 + " x"))
        XCTAssertEqual(CommandGrammar.words(at32)?.count, 32)
        // Character cap.
        let long = "open slack" + String(repeating: " ", count: 2_000)
        XCTAssertEqual(CommandRouter.routeCommandKey(long, catalog: c), .failed(.unrecognised))
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto " + long, catalog: c, prefixEnabled: true), .dictation)
    }

    func test_verbProperty() {
        XCTAssertEqual(ResolvedCommand.open(Self.slack, state: .running).verb, .open)
        XCTAssertEqual(ResolvedCommand.switchTo(Self.slack, state: .running).verb, .switchTo)
        XCTAssertEqual(ResolvedCommand.hide(Self.slack).verb, .hide)
        XCTAssertEqual(ResolvedCommand.openFolder(Self.invoices).verb, .open)
        XCTAssertEqual(ResolvedCommand.openLink(Self.standup).verb, .open)
        XCTAssertEqual(ResolvedCommand.runShortcut(CatalogShortcut(name: "x")).verb, .run)
    }

    func test_failureKindsArePayloadFree() {
        let cases: [(CommandFailure, CommandFailure.Kind)] = [
            (.unrecognised, .unrecognised), (.notFound(.app, spoken: "x"), .notFound),
            (.ambiguous(spoken: "x", candidates: []), .ambiguous), (.notRunning(Self.mail), .notRunning),
            (.shortcutsOff, .shortcutsOff), (.confirmKeyUnavailable, .confirmKeyUnavailable),
        ]
        for (failure, kind) in cases { XCTAssertEqual(failure.kind, kind) }
        XCTAssertEqual(Set(cases.map(\.1)), Set(CommandFailure.Kind.allCases))
    }

    func test_matchesAreDedupedByIDNotInputs() {
        var c = Self.catalog()
        let desktop = CatalogApp(name: "Slack Desktop", id: Self.slack.id)
        c.apps.append(desktop)
        // Second name for the same bundle ID still matches (and is the app returned)...
        XCTAssertEqual(CommandRouter.routeCommandKey("open desktop", catalog: c),
                       .resolved(.open(desktop, state: .running)))
        // ...and two names matching one ID are not ambiguous.
        let browser = CatalogApp(name: "Chrome Browser", id: Self.chrome.id)
        c.apps.append(browser)
        XCTAssertEqual(CommandRouter.routeCommandKey("open chrome", catalog: c),
                       .resolved(.open(Self.chrome, state: .running)))
        XCTAssertEqual(CommandRouter.routeCommandKey("switch to browser", catalog: c),
                       .resolved(.switchTo(browser, state: .running)))
    }

    func test_hideFrontmostAppNotInRunningIDsCountsAsRunning() {
        var c = Self.catalog()
        c.runningAppIDs.remove(Self.safari.id)
        c.frontmostAppID = Self.safari.id
        XCTAssertEqual(CommandRouter.routeCommandKey("hide safari", catalog: c), .resolved(.hide(Self.safari)))
    }

    func test_prefixTwoWordRuleForShortcutsOffAndNotRunning() {
        let off = Self.catalog(shortcuts: false)
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto run backup", catalog: off, prefixEnabled: true),
                       .commandError(.shortcutsOff))
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto run backup now please", catalog: off, prefixEnabled: true),
                       .commandError(.shortcutsOff))  // "please" is trailing filler: 2 target words
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto run the weekly backup job", catalog: off, prefixEnabled: true),
                       .dictation)
        let c = Self.catalog()
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto hide mail", catalog: c, prefixEnabled: true),
                       .commandError(.notRunning(Self.mail)))
        XCTAssertEqual(CommandRouter.routeDictationKey("Sotto hide the mail app", catalog: c, prefixEnabled: true),
                       .dictation)
    }
}
