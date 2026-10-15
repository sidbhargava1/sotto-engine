// Protected spans through DictationSession: the model sees placeholders only, the text lands
// exactly, and a placeholder the model loses degrades to the raw transcript with the text in.
import XCTest
@_spi(Testing) import SottoCore
@testable import SottoCoreTestSupport

/// A cleanup stand-in that records what it was asked and answers with `transform(request)`.
actor EchoBackend: CleanupBackend {
    private(set) var requests: [CleanupRequest] = []
    private let transform: @Sendable (CleanupRequest) -> String

    init(_ transform: @escaping @Sendable (CleanupRequest) -> String = { $0.rawTranscript }) { self.transform = transform }

    nonisolated func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(request)
                continuation.yield(self.transform(request))
                continuation.finish()
            }
        }
    }

    private func record(_ request: CleanupRequest) { requests.append(request) }
}

final class ProtectedSessionTests: SessionTestCase {
    static let phrases = [
        ProtectedPhrase(spoken: "my calendar link", text: "https://cal.com/me"),
        ProtectedPhrase(spoken: "standup template", text: "Yesterday: \nToday:\nBlockers: none"),
    ]

    private func harness(_ said: String, backend: any CleanupBackend, terminal: Bool = false, dictionary: [DictionaryTerm] = [], settings: Settings = Settings(), history: any HistoryRecording = NoHistory()) -> Harness {
        makeHarness(
            transcriber: FixtureTranscriber([.text(said)]), backend: backend,
            context: FakeContextProvider(makeTestContext(isTerminalClass: terminal)),
            dictionary: dictionary, settings: settings, history: history, protectedPhrases: Self.phrases
        )
    }

    func test_PS01_midSentenceTheModelSeesAPlaceholderAndTheTextLandsInPlace() async {
        let backend = EchoBackend { $0.rawTranscript.replacingOccurrences(of: "sure here's", with: "Sure, here's") + "." }
        let h = harness("sure here's my calendar link", backend: backend)
        await runUtterance(h)
        let seen = await backend.requests
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].rawTranscript, "sure here's ⟦1⟧")
        XCTAssertEqual(seen[0].protectedTokens, ["⟦1⟧"])
        XCTAssertFalse(PromptBuilder.build(seen[0]).tail.contains("cal.com"), "the model never sees the text")
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "Sure, here's https://cal.com/me.")
    }

    func test_PS02_aTriggerAloneSkipsTheModelAndLandsAsWritten() async {
        let backend = EchoBackend()
        let h = harness("um, standup template.", backend: backend)
        let states = await collectStates(h)
        await runUtterance(h)
        let calls = await backend.requests.count
        XCTAssertEqual(calls, 0)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "Yesterday: \nToday:\nBlockers: none", "no capital, no full stop, trailing space kept")
        let settled = await states.settled()
        XCTAssertFalse(settled.contains { if case .degraded = $0 { true } else { false } }, "\(settled)")
    }

    func test_PS03_twoTriggersInOneDictationBothExpandInOrder() async {
        let h = harness("my calendar link and standup template", backend: EchoBackend())
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "https://cal.com/me and Yesterday: \nToday:\nBlockers: none")
    }

    func test_PS04_aTerminalGetsSpacesAndNeverAReturn() async {
        let h = harness("run the standup template", backend: EchoBackend { $0.rawTranscript }, terminal: true)
        await runUtterance(h)
        let injected = await h.unicode.injectedText()
        XCTAssertFalse(injected.contains("\n"))
        XCTAssertEqual(injected, "run the Yesterday:  Today: Blockers: none")
    }

    func test_PS05_trailingSpacesInsideTheTextSurviveTheLineEndTrim() async {
        let h = harness("standup template please", backend: EchoBackend { $0.rawTranscript })
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "Yesterday: \nToday:\nBlockers: none please")
    }

    func test_PS06_aDroppedPlaceholderTypesTheRawTranscriptWithTheTextInAndDegrades() async {
        let backend = EchoBackend { _ in "Sure, here's the link." }
        let h = harness("sure here's my calendar link", backend: backend)
        let states = await collectStates(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "sure here's https://cal.com/me")
        let settled = await states.settled()
        XCTAssertTrue(settled.contains(.degraded(.rawTyped)), "\(settled)")
    }

    func test_PS07_aRepeatedOrInventedPlaceholderDegradesToo() async {
        for answer in ["⟦1⟧ ⟦1⟧", "⟦1⟧ and ⟦2⟧"] {
            let h = harness("send my calendar link", backend: EchoBackend { _ in answer })
            let states = await collectStates(h)
            await runUtterance(h)
            let injected = await h.ax.injectedText()
            XCTAssertEqual(injected, "send https://cal.com/me", answer)
            let settled = await states.settled()
            XCTAssertTrue(settled.contains(.degraded(.rawTyped)), "\(answer) \(settled)")
        }
    }

    func test_PS08_aFailedModelFallsBackToTheSpokenFormWithTheTextIn() async {
        let backend = FixtureBackend(steps: [], ending: .fail(CleanupError.modelFailed("x")))
        let h = harness("sure my calendar link", backend: backend)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "sure https://cal.com/me")
    }

    func test_PS08b_theOutputCapFallsBackToRawUnderProtection() async {
        let backend = FixtureBackend(steps: [.init("Sure ")], ending: .fail(CleanupError.outputCapReached))
        let h = harness("sure my calendar link", backend: backend)
        let states = await collectStates(h)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "sure https://cal.com/me", "a cut-off answer can't carry the placeholder: raw with the text in")
        let settled = await states.settled()
        XCTAssertTrue(settled.contains(.degraded(.rawTyped)), "\(settled)")
    }

    func test_PS09_aStalledModelFallsBackToo() async {
        let backend = FixtureBackend(steps: [.init("never", after: .seconds(5))])
        let h = makeHarness(
            transcriber: FixtureTranscriber([.text("sure my calendar link")]), backend: backend,
            coalescerConfig: CoalescerConfig(delivery: .whole, flushInterval: .milliseconds(5), firstTokenTimeout: .milliseconds(200), stallTimeout: .milliseconds(60)),
            protectedPhrases: Self.phrases)
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "sure https://cal.com/me")
    }

    func test_PS10_theDictionaryRewritesAroundAPlaceholderNotInsideOne() async {
        let terms = [DictionaryTerm("Sotto (soto)"), DictionaryTerm("One (1)")]
        let backend = EchoBackend()
        let h = harness("soto my calendar link", backend: backend, dictionary: terms)
        await runUtterance(h)
        let seen = await backend.requests
        XCTAssertEqual(seen.first?.rawTranscript, "Sotto ⟦1⟧")
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "Sotto https://cal.com/me")
    }

    func test_PS11_aHeardAsVariantInsideATriggerDoesNotBreakIt() async {
        let h = harness("my calendar link", backend: EchoBackend(), dictionary: [DictionaryTerm("CalLink (calendar link)")])
        await runUtterance(h)
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "https://cal.com/me", "phrases match the raw transcript first")
    }

    func test_PS12_historyKeepsWhatWasSaidAndWhatLanded() async {
        let history = RecordingHistory()
        let h = harness("send my calendar link", backend: EchoBackend(), history: history)
        await runUtterance(h)
        XCTAssertEqual(history.records.first?.rawText, "send my calendar link")
        XCTAssertEqual(history.records.first?.cleanText, "send https://cal.com/me")
        XCTAssertEqual(history.records.first?.words, 4, "the words that were spoken, not the inserted text")
        XCTAssertEqual(history.records.first?.protectedSpans, 1)
    }

    func test_PS14_aLongTemplateDoesNotInflateTheWordCount() async {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let history = RecordingHistory()
        let h = makeHarness(
            transcriber: FixtureTranscriber([.text("standup template")]), backend: EchoBackend(), history: history,
            protectedPhrases: [ProtectedPhrase(spoken: "standup template", text: long)])
        await runUtterance(h)
        XCTAssertEqual(history.records.first?.cleanText, long)
        XCTAssertEqual(history.records.first?.words, 2)
    }

    func test_PS13_noPhrasesLeavesTheRequestAndOutputAlone() async {
        let backend = EchoBackend { $0.rawTranscript.uppercased() }
        let h = makeHarness(transcriber: FixtureTranscriber([.text("hello my calendar link")]), backend: backend)
        await runUtterance(h)
        let seen = await backend.requests
        XCTAssertEqual(seen.first?.rawTranscript, "hello my calendar link")
        XCTAssertEqual(seen.first?.protectedTokens, [])
        let injected = await h.ax.injectedText()
        XCTAssertEqual(injected, "HELLO MY CALENDAR LINK")
    }
}
