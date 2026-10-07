// Backend contract against a stub engine (docs/phase2-test-scenarios.md LB-/WR- ids).
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class ModelCleanupBackendTests: XCTestCase {
    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async -> (String, Error?) {
        let c = await collectStream(stream)
        return (c.text, c.error)
    }

    private static func request(_ text: String = "hello there", dictionary: [String] = []) -> CleanupRequest {
        CleanupRequest(rawTranscript: text, dictionary: dictionary, targetContext: makeTestContext())
    }

    private func loaded(_ engine: StubEngine, dictionary: [String] = []) async throws -> ModelCleanupBackend {
        let backend = ModelCleanupBackend(engine: engine)
        try await backend.load(dictionary: dictionary)
        return backend
    }

    func test_LB01_chunksArriveInOrder() async throws {
        let backend = try await loaded(StubEngine(pieces: ["A", "B", "C"]))
        let (text, error) = await Self.collect(backend.clean(Self.request()))
        XCTAssertEqual(text, "ABC")
        XCTAssertNil(error)
    }

    func test_LB02_newRequestSupersedesAnInFlightDecode() async throws {
        let engine = StubEngine(pieces: Array(repeating: "a", count: 50), tokenDelay: 0.005)
        let backend = try await loaded(engine)
        let beforeDecode = engine.entries().count
        let first = backend.clean(Self.request())
        let firstResult = Task { await collectStream(first) }
        await waitUntil("the decode to start") { engine.entries().dropFirst(beforeDecode).contains("sample") }
        engine.pieces = ["B"]
        let (second, secondError) = await Self.collect(backend.clean(Self.request()))
        let firstError = await firstResult.value.error
        XCTAssertEqual(firstError as? CleanupError, .superseded)
        XCTAssertEqual(second, "B")
        XCTAssertNil(secondError)
        let tails = engine.entries().filter { $0.hasPrefix("tail@") }
        XCTAssertEqual(Set(tails).count, 1, "both tails replaced back to the same prefix length: \(tails)")
    }

    func test_LB06_outputCapStopsARunawayDecode() async throws {
        let engine = StubEngine()
        engine.endless = true
        let backend = try await loaded(engine)
        let (text, error) = await Self.collect(backend.clean(Self.request("hi")))
        XCTAssertEqual(error as? CleanupError, .outputCapReached)
        let tailTokens = ChatML.render(ChatML.tail(PromptBuilder.build(Self.request("hi")).tail)).utf8.count
        XCTAssertEqual(text.count, 2 * tailTokens + 64)
    }

    func test_LB07_contextOverflowFailsBeforeDecoding() async throws {
        // Sized off the real prefix so a short request fits and only the long one overflows.
        let prefixBytes = ChatML.render(ChatML.prefix(PromptBuilder.build(Self.request("hi")).prefix)).utf8.count
        let engine = StubEngine(contextSize: prefixBytes + 1000)
        let backend = try await loaded(engine)
        let (_, shortError) = await Self.collect(backend.clean(Self.request("hi")))
        XCTAssertNil(shortError)
        let afterLoad = engine.entries().count
        let (_, error) = await Self.collect(backend.clean(Self.request(String(repeating: "word ", count: 200))))
        XCTAssertEqual(error as? CleanupError, .contextOverflow)
        XCTAssertFalse(engine.entries()[afterLoad...].contains { $0.hasPrefix("tail@") })
    }

    func test_LB08_droppingTheStreamStopsSampling() async throws {
        let engine = StubEngine(pieces: Array(repeating: "a", count: 200), tokenDelay: 0.002)
        let backend = try await loaded(engine)
        var stream: AsyncThrowingStream<String, Error>? = backend.clean(Self.request())
        var iterator = stream!.makeAsyncIterator()
        _ = try await iterator.next()
        stream = nil
        _ = consume iterator
        // Wait for sampling to go quiet (a slow runner propagates the cancel late), then check it
        // stopped early: run to the end, it would reach all 200.
        var samplesNow = -1
        await waitUntil("sampling to stop") {
            let then = engine.entries().filter { $0 == "sample" }.count
            try? await Task.sleep(for: .milliseconds(60))
            samplesNow = engine.entries().filter { $0 == "sample" }.count
            return then == samplesNow
        }
        XCTAssertLessThan(samplesNow, 200)
    }

    func test_LB10_stalePrefixIsRebuiltBeforeDecoding() async throws {
        let engine = StubEngine()
        let backend = try await loaded(engine, dictionary: ["Sotto"])
        let launchPrefill = try XCTUnwrap(engine.entries().first { $0.hasPrefix("prefill:") })
        let afterLoad = engine.entries().count
        _ = await Self.collect(backend.clean(Self.request(dictionary: ["Sotto", "Klaus"])))
        let log = engine.entries()[afterLoad...].filter { $0 != "sample" }
        XCTAssertEqual(log.count, 2, "\(log)")
        XCTAssertTrue(log.first!.hasPrefix("prefill:"), "re-prefill precedes the tail: \(log)")
        XCTAssertNotEqual(log.first, launchPrefill)
        XCTAssertTrue(log.last!.hasPrefix("tail@"))
    }

    func test_loadWarmsUpOneDecodeOffTheHotkeyPath() async throws {
        let engine = StubEngine()
        _ = try await loaded(engine)
        let steps = engine.entries().filter { $0 != "sample" }
        let prefixTokens = try XCTUnwrap(steps.dropFirst().first?.split(separator: ":").last)
        XCTAssertEqual(steps, ["load", "prefill:\(prefixTokens)", "tail@\(prefixTokens)"])
    }

    func test_LB11_beforeLoadFinishesRequestsFailFastAsNotReady() async throws {
        let backend = ModelCleanupBackend(engine: StubEngine())
        let start = ContinuousClock.now
        let (_, error) = await Self.collect(backend.clean(Self.request()))
        XCTAssertEqual(error as? CleanupError, .notReady)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500), "well under the 1.5 s first-token wait")
    }

    func test_WR06_requestDuringRebuildWaitsAndUsesTheNewPrefix() async throws {
        let engine = StubEngine()
        let backend = try await loaded(engine)
        engine.prefillDelay = 0.1
        let rebuild = Task { await backend.prepare(dictionary: ["Klaus"]) }
        try await Task.sleep(for: .milliseconds(20))
        let (text, error) = await Self.collect(backend.clean(Self.request(dictionary: ["Klaus"])))
        await rebuild.value
        XCTAssertEqual(text, "Hello there.")
        XCTAssertNil(error)
        XCTAssertEqual(engine.entries().filter { $0.hasPrefix("prefill:") }.count, 2, "one rebuild, reused by the request")
    }

    func test_WR07_rebuildWaitsForAnActiveDecode() async throws {
        let engine = StubEngine(pieces: Array(repeating: "a", count: 20), tokenDelay: 0.003)
        let backend = try await loaded(engine)
        let req = Self.request()
        let beforeDecode = engine.entries().count
        let decode = Task { await collectStream(backend.clean(req)) }
        await waitUntil("the decode to start") { engine.entries().dropFirst(beforeDecode).contains("sample") }
        await backend.prepare(dictionary: ["Klaus"])
        _ = await decode.value
        let log = engine.entries()
        let lastSample = try XCTUnwrap(log.lastIndex(of: "sample"))
        let rebuild = try XCTUnwrap(log.lastIndex { $0.hasPrefix("prefill:") })
        XCTAssertGreaterThan(rebuild, lastSample, "prefill never interleaves with sampling")
    }

    func test_shutdownUnloadsAndLaterRequestsGoRaw() async throws {
        let engine = StubEngine()
        let backend = try await loaded(engine)
        await backend.shutdown()
        XCTAssertEqual(engine.entries().last, "unload")
        let (_, error) = await Self.collect(backend.clean(Self.request()))
        XCTAssertEqual(error as? CleanupError, .notReady)
    }

    func test_beginShutdownStopsALongDecodePromptly() async throws {
        let engine = StubEngine(pieces: Array(repeating: "a", count: 2000), tokenDelay: 0.01)
        let backend = try await loaded(engine)
        let req = Self.request()
        let beforeDecode = engine.entries().count
        let decode = Task { await collectStream(backend.clean(req)) }
        await waitUntil("the decode to start") { engine.entries().dropFirst(beforeDecode).contains("sample") }
        let start = ContinuousClock.now
        backend.beginShutdown()
        await backend.shutdown()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "shutdown waited out the 20 s decode")
        XCTAssertEqual(engine.entries().last, "unload")
        let result = await decode.value
        XCTAssertEqual(result.error as? CleanupError, .superseded)
    }

    func test_WR08_loadFailureLeavesTheBackendNotReady() async {
        let engine = StubEngine()
        engine.loadError = CleanupError.modelFailed("corrupt gguf")
        let backend = ModelCleanupBackend(engine: engine)
        do {
            try await backend.load(dictionary: [])
            XCTFail("load should throw")
        } catch {}
        let (_, error) = await Self.collect(backend.clean(Self.request()))
        XCTAssertEqual(error as? CleanupError, .notReady)
    }
}
