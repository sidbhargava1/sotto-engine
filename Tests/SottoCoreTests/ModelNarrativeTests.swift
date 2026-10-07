// Rulings must-fix 5 / VP-69–73: the narrative shares the one context with cleanup; a press
// preempts it and the next cleanup never decodes on the narrative's KV.
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class ModelNarrativeTests: XCTestCase {
    private func loaded(_ engine: StubEngine) async throws -> (ModelCleanupBackend, String) {
        let backend = ModelCleanupBackend(engine: engine)
        try await backend.load(dictionary: [])
        let prefill = try XCTUnwrap(engine.entries().first { $0.hasPrefix("prefill:") })
        return (backend, prefill)
    }

    private func request() -> CleanupRequest {
        CleanupRequest(rawTranscript: "hello there", dictionary: [], targetContext: makeTestContext())
    }

    func test_VP61_generateStreamsThenRestoresTheDictationPrefix() async throws {
        let engine = StubEngine(pieces: ["Write ", "short ", "sentences."])
        let (backend, dictationPrefill) = try await loaded(engine)
        let mark = engine.entries().count
        let result = await collectStream(backend.generate(system: "sys", user: "stats", maxTokens: 300))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "Write short sentences.")
        let steps = engine.entries()[mark...].filter { $0 != "sample" }
        XCTAssertEqual(steps.count, 3, "\(steps)")
        XCTAssertNotEqual(steps.first, dictationPrefill, "narrative prefills its own prompt")
        XCTAssertEqual(steps.last, dictationPrefill, "dictation prefix re-prefilled after")
    }

    func test_VP69_VP71_pressPreemptsWithinATokenAndNextCleanupUsesAFreshPrefix() async throws {
        let engine = StubEngine(tokenDelay: 0.005)
        engine.endless = true
        let (backend, dictationPrefill) = try await loaded(engine)
        let beforeDecode = engine.entries().count
        let narrative = Task { await collectStream(backend.generate(system: "sys", user: "stats", maxTokens: 4_000)) }
        await waitUntil("the decode to start") { engine.entries().dropFirst(beforeDecode).contains("sample") }
        let samples = { engine.entries().filter { $0 == "sample" }.count }
        let pressed = ContinuousClock.now
        backend.preempt()  // what the app does on press, then it queues prepare
        let samplesAtPress = samples()
        await backend.prepare(dictionary: [])
        let result = await narrative.value
        XCTAssertEqual(result.error as? CleanupError, .superseded)
        // "Within a token" counted in tokens, not wall time: the one in flight, plus one for the race.
        XCTAssertLessThanOrEqual(samples() - samplesAtPress, 2, "the decode ran on after the press")
        XCTAssertLessThan(ContinuousClock.now - pressed, .milliseconds(500), "a hang guard: undisturbed, the decode never ends")
        let afterPress = engine.entries().count
        engine.endless = false
        let cleanup = await collectStream(backend.clean(request()))
        XCTAssertNil(cleanup.error)
        XCTAssertEqual(cleanup.text, "Hello there.")
        // prepare already restored it: the cleanup decodes straight onto the dictation prefix.
        let log = engine.entries()
        let restored = try XCTUnwrap(log.lastIndex(of: dictationPrefill))
        let tail = try XCTUnwrap(log.lastIndex { $0.hasPrefix("tail@") })
        XCTAssertLessThan(restored, afterPress)
        XCTAssertGreaterThan(tail, restored)
        XCTAssertEqual(log[afterPress...].filter { $0.hasPrefix("prefill:") }, [], "no second prefill")
    }

    func test_VP71_cleanupWithoutPrepareStillRebuildsThePrefix() async throws {
        let engine = StubEngine(tokenDelay: 0.005)
        engine.endless = true
        let (backend, dictationPrefill) = try await loaded(engine)
        let beforeDecode = engine.entries().count
        let narrative = Task { await collectStream(backend.generate(system: "sys", user: "stats", maxTokens: 4_000)) }
        await waitUntil("the decode to start") { engine.entries().dropFirst(beforeDecode).contains("sample") }
        engine.endless = false
        let mark = engine.entries().count
        let cleanup = await collectStream(backend.clean(request()))  // a cleanup request alone supersedes it
        let preempted = await narrative.value
        XCTAssertEqual(preempted.error as? CleanupError, .superseded)
        XCTAssertNil(cleanup.error)
        let steps = engine.entries()[mark...].filter { $0 != "sample" }
        XCTAssertEqual(steps.first, dictationPrefill, "re-prefill before the tail: \(steps)")
        XCTAssertTrue(steps.last?.hasPrefix("tail@") ?? false)
    }

    func test_VP72_threePressesNeverOverlapDecodes() async throws {
        let engine = StubEngine(tokenDelay: 0.003)
        engine.endless = true
        let (backend, _) = try await loaded(engine)
        let beforeDecode = engine.entries().count
        let narrative = Task { await collectStream(backend.generate(system: "sys", user: "stats", maxTokens: 4_000)) }
        await waitUntil("the decode to start") { engine.entries().dropFirst(beforeDecode).contains("sample") }
        for _ in 0..<3 {
            backend.preempt()
            await backend.prepare(dictionary: [])
        }
        let preempted = await narrative.value
        XCTAssertEqual(preempted.error as? CleanupError, .superseded)
        let samplesAfter = engine.entries().count
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(engine.entries().count, samplesAfter, "nothing decodes once preempted")
    }

    func test_VP73_cancellingTheConsumerStopsAndRestores() async throws {
        let engine = StubEngine(tokenDelay: 0.003)
        engine.endless = true
        let (backend, dictationPrefill) = try await loaded(engine)
        let beforeDecode = engine.entries().count
        let narrative = Task { await collectStream(backend.generate(system: "sys", user: "stats", maxTokens: 4_000)) }
        await waitUntil("the decode to start") { engine.entries().dropFirst(beforeDecode).contains("sample") }
        narrative.cancel()
        _ = await narrative.value
        await backend.prepare(dictionary: [])  // a later queue hop: the restore has already run
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.entries().last, dictationPrefill)
    }

    func test_generateFailsFastWhenNotReadyOrTooLong() async throws {
        let cold = await collectStream(ModelCleanupBackend(engine: StubEngine()).generate(system: "s", user: "u", maxTokens: 10))
        XCTAssertEqual(cold.error as? CleanupError, .notReady)
        let engine = StubEngine()
        let (backend, dictationPrefill) = try await loaded(engine)
        let long = await collectStream(backend.generate(system: "s", user: String(repeating: "x", count: 9_000), maxTokens: 300))
        XCTAssertEqual(long.error as? CleanupError, .contextOverflow)
        XCTAssertEqual(engine.entries().last { $0.hasPrefix("prefill:") }, dictationPrefill)
    }

    func test_capReachedReturnsWhatWasWritten() async throws {
        let engine = StubEngine()
        let (backend, _) = try await loaded(engine)
        engine.endless = true
        let r = await collectStream(backend.generate(system: "s", user: "u", maxTokens: 5))
        XCTAssertEqual(r.error as? CleanupError, .outputCapReached)
        XCTAssertEqual(r.text, "xxxxx")
    }
}
