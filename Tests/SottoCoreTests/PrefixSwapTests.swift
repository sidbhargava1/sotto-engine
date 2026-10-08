// Staged dictionary re-prefill (the dictionary race): the live prefix keeps serving requests
// while the new one builds in a second sequence, then swaps.
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class PrefixSwapTests: XCTestCase {
    private static func request(_ dictionary: [String]) -> CleanupRequest {
        CleanupRequest(rawTranscript: "hello there", dictionary: dictionary, targetContext: makeTestContext())
    }

    /// Time to the first piece (or the end of the stream) and the result.
    private func timed(_ backend: ModelCleanupBackend, _ dictionary: [String]) async -> (ttft: Duration, text: String, error: Error?) {
        let start = ContinuousClock.now
        var first: Duration?
        var text = ""
        do {
            for try await piece in backend.clean(Self.request(dictionary)) {
                if first == nil { first = ContinuousClock.now - start }
                text += piece
            }
            return (first ?? ContinuousClock.now - start, text, nil)
        } catch { return (first ?? ContinuousClock.now - start, text, error) }
    }

    private func loaded(staged: Bool, stageDelay: TimeInterval = 0, prefillDelay: TimeInterval = 0, contextSize: Int = 16384) async throws -> (StubEngine, ModelCleanupBackend, [ModelBackendEvent]) {
        let engine = StubEngine(contextSize: contextSize)
        engine.staged = staged
        let backend = ModelCleanupBackend(engine: engine)
        try await backend.load(dictionary: ["Sotto"])
        engine.stageDelay = stageDelay
        engine.prefillDelay = prefillDelay
        return (engine, backend, [])
    }

    /// The race: an edit, the watcher's re-prefill 0.5 s later, a dictation at 0 / 0.5 / 1.0 s.
    /// Rebuilding in place would hold each request for the remaining prefill (1.4 s here).
    func test_raceAt0_05_10_neverWaitsAndNeverFallsBackToRaw() async throws {
        for offset in [0.0, 0.5, 1.0] {
            let (engine, backend, _) = try await loaded(staged: true, stageDelay: 0.02)
            let liveLength = try XCTUnwrap(Int(try XCTUnwrap(engine.entries().first { $0.hasPrefix("prefill:") }).split(separator: ":").last!))
            let dictionary = ["Sotto", "Klaus"]
            let watcher = Task {
                try? await Task.sleep(for: .milliseconds(500))
                await backend.prepare(dictionary: dictionary)
            }
            try await Task.sleep(for: .seconds(offset))
            let result = await timed(backend, dictionary)
            XCTAssertNil(result.error, "offset \(offset)")
            XCTAssertEqual(result.text, "Hello there.", "offset \(offset)")
            await watcher.value
            let log = engine.entries()
            // Structural: the request decoded on the live prefix, before the swap, and nothing rebuilt in place.
            let served = try XCTUnwrap(log.lastIndex(of: "tail@\(liveLength)"), "offset \(offset)")
            let commit = try XCTUnwrap(log.firstIndex(of: "commit"), "offset \(offset)")
            XCTAssertLessThan(served, commit, "offset \(offset): served before the swap")
            XCTAssertEqual(log.filter { $0 == "commit" }.count, 1, "offset \(offset): one swap")
            XCTAssertEqual(log.filter { $0.hasPrefix("prefill:") }.count, 1, "offset \(offset): never rebuilt in place")
            XCTAssertLessThan(result.ttft, .seconds(1), "offset \(offset): far below the whole prefill, loose enough for a busy machine")
        }
    }

    func test_controlRebuildInPlaceHoldsTheRequest() async throws {
        let (_, backend, _) = try await loaded(staged: false, prefillDelay: 0.5)
        let result = await timed(backend, ["Sotto", "Klaus"])
        XCTAssertGreaterThan(result.ttft, .milliseconds(450), "the in-place path waits for the whole prefill")
    }

    func test_mismatchedRequestDecodesAgainstTheLivePrefixThenTheNewOneTakesOver() async throws {
        let (engine, backend, _) = try await loaded(staged: true, stageDelay: 0.005)
        let livePrefill = try XCTUnwrap(engine.entries().first { $0.hasPrefix("prefill:") })
        let liveLength = try XCTUnwrap(Int(livePrefill.split(separator: ":").last!))
        let new = ["Sotto", "Klaus"]
        let first = await timed(backend, new)
        XCTAssertEqual(first.text, "Hello there.")
        XCTAssertTrue(engine.entries().contains("tail@\(liveLength)"), "decoded at the live prefix length")
        // Wait for the build to finish, then the same dictionary matches the new prefix.
        await backend.prepare(dictionary: new)
        let newLength = liveLength + "\nKlaus".utf8.count
        let before = engine.entries().count
        let second = await timed(backend, new)
        XCTAssertEqual(second.text, "Hello there.")
        let after = engine.entries()[before...]
        XCTAssertTrue(after.contains("tail@\(newLength)"), "\(after)")
        XCTAssertFalse(after.contains { $0.hasPrefix("stage") }, "a matching request starts no build")
    }

    func test_stagingSharesTheUnchangedLeadingTokens() async throws {
        let (engine, backend, _) = try await loaded(staged: true)
        await backend.prepare(dictionary: ["Sotto", "Zed"])
        let begin = try XCTUnwrap(engine.entries().first { $0.hasPrefix("stage-begin:") })
        let prefill = try XCTUnwrap(engine.entries().first { $0.hasPrefix("prefill:") })
        let live = Int(prefill.split(separator: ":").last!)!
        let closing = "<|im_end|>\n".utf8.count  // the system turn closes after the last term
        XCTAssertEqual(begin, "stage-begin:\(live - closing)", "everything up to the new term is shared")
        XCTAssertEqual(engine.entries().filter { $0.hasPrefix("stage:") }.reduce(0) { $0 + Int($1.split(separator: ":")[1].split(separator: "@")[0])! }, "\nZed".utf8.count + closing)
    }

    func test_aSecondEditMidBuildSupersedesTheFirst() async throws {
        let (engine, backend, _) = try await loaded(staged: true, stageDelay: 0.02)
        // Long first term so the build spans many batches.
        let a = ["Sotto", String(repeating: "A", count: 1000)]
        let b = ["Sotto", "Klaus"]
        let first = Task { await backend.prepare(dictionary: a) }
        await waitUntil("the build to start") { engine.entries().contains { $0.hasPrefix("stage:") } }
        await backend.prepare(dictionary: b)
        await first.value
        XCTAssertEqual(engine.entries().filter { $0 == "commit" }.count, 1, "only the newest build swaps in")
        XCTAssertTrue(engine.entries().contains("discard"))
        let before = engine.entries().count
        _ = await timed(backend, b)
        XCTAssertFalse(engine.entries()[before...].contains { $0.hasPrefix("stage") || $0.hasPrefix("prefill") }, "B is the live prefix")
    }

    func test_undoingTheEditMidBuildDiscardsTheStage() async throws {
        let (engine, backend, _) = try await loaded(staged: true, stageDelay: 0.02)
        let build = Task { await backend.prepare(dictionary: ["Sotto", String(repeating: "A", count: 1000)]) }
        await waitUntil("the build to start") { engine.entries().contains { $0.hasPrefix("stage:") } }
        await backend.prepare(dictionary: ["Sotto"])
        await build.value
        XCTAssertFalse(engine.entries().contains("commit"))
        XCTAssertTrue(engine.entries().contains("discard"))
    }

    func test_shutdownMidBuildNeverCommits() async throws {
        let (engine, backend, _) = try await loaded(staged: true, stageDelay: 0.02)
        let build = Task { await backend.prepare(dictionary: ["Sotto", String(repeating: "A", count: 1000)]) }
        await waitUntil("the build to start") { engine.entries().contains { $0.hasPrefix("stage:") } }
        await backend.shutdown()
        await build.value
        XCTAssertFalse(engine.entries().contains("commit"))
        XCTAssertEqual(engine.entries().last, "unload")
    }

    func test_droppingTheRequestStreamDoesNotCancelTheBuild() async throws {
        let (engine, backend, _) = try await loaded(staged: true, stageDelay: 0.01)
        let new = ["Sotto", "Klaus", String(repeating: "B", count: 300)]
        var stream: AsyncThrowingStream<String, Error>? = backend.clean(Self.request(new))
        var it = stream!.makeAsyncIterator()
        _ = try await it.next()
        stream = nil
        await backend.prepare(dictionary: new)
        XCTAssertEqual(engine.entries().filter { $0 == "commit" }.count, 1)
    }

    func test_aNarrativeDuringABuildRestoresTheNewestDictionary() async throws {
        let (engine, backend, _) = try await loaded(staged: true, stageDelay: 0.02)
        let new = ["Sotto", String(repeating: "A", count: 600)]
        let build = Task { await backend.prepare(dictionary: new) }
        await waitUntil("the build to start") { engine.entries().contains { $0.hasPrefix("stage:") } }
        for try await _ in backend.generate(system: "s", user: "u", maxTokens: 8) {}
        await build.value
        let before = engine.entries().count
        _ = await timed(backend, new)
        XCTAssertFalse(engine.entries()[before...].contains { $0.hasPrefix("prefill") || $0.hasPrefix("stage") }, "the narrative's restore rebuilt the newest prefix")
    }

    func test_aSecondSequenceThatWouldNotFitFallsBackToRebuildingInPlace() async throws {
        // Prefix is ~4.3K stub tokens; leave less than the reserve beside a changed tail.
        let (engine, backend, _) = try await loaded(staged: true, contextSize: 5000)
        await backend.prepare(dictionary: ["Sotto", "Klaus"])
        XCTAssertFalse(engine.entries().contains { $0.hasPrefix("stage") })
        XCTAssertEqual(engine.entries().filter { $0.hasPrefix("prefill:") }.count, 2)
    }

    /// The build claims all its cells up front: a long tail that fits beside the cells staged so far
    /// but not beside the finished build cancels the build (the request still decodes), instead of
    /// starving a later batch of free cells.
    func test_aLongTailMidBuildCancelsTheBuildBeforeItCanRunOutOfCells() async throws {
        let (engine, backend, _) = try await loaded(staged: true, stageDelay: 0.001, contextSize: 5500)
        let big = ["Sotto", String(repeating: "C", count: 300)]  // a 300-cell build, admitted by the reserve
        let live = try XCTUnwrap(Int(try XCTUnwrap(engine.entries().first { $0.hasPrefix("prefill:") }).split(separator: ":").last!))
        let tail = String(repeating: "word ", count: 66)  // about 400 tail cells: fits beside the live prefix alone, not beside the build
        let r = CleanupRequest(rawTranscript: tail, dictionary: big, targetContext: makeTestContext())
        let (text, error) = await { let c = await collectStream(backend.clean(r)); return (c.text, c.error) }()
        XCTAssertNil(error, "the request decodes")
        XCTAssertEqual(text, "Hello there.")
        XCTAssertTrue(engine.entries().contains("discard"), "the build was cancelled")
        XCTAssertFalse(engine.entries().contains("commit"))
        XCTAssertTrue(engine.entries().contains("tail@\(live)"))
        // The edit is not lost: the next request starts the build again, and it completes.
        await backend.prepare(dictionary: big)
        XCTAssertEqual(engine.entries().filter { $0 == "commit" }.count, 1)
    }

    func test_aStagedDecodeErrorCancelsTheBuildAndTheLivePrefixKeepsServing() async throws {
        let engine = StubEngine(contextSize: 16384)
        engine.staged = true
        let events = EventLog()
        let backend = ModelCleanupBackend(engine: engine, onEvent: events.add)
        try await backend.load(dictionary: ["Sotto"])
        let live = try XCTUnwrap(Int(try XCTUnwrap(engine.entries().first { $0.hasPrefix("prefill:") }).split(separator: ":").last!))
        engine.failStageAtBatch = 3
        await backend.prepare(dictionary: ["Sotto", String(repeating: "D", count: 600)])
        XCTAssertTrue(events.failed, "reported")
        XCTAssertTrue(engine.entries().contains("discard"))
        XCTAssertFalse(engine.entries().contains("commit"))
        let r = await timed(backend, ["Sotto"])  // the live dictionary still matches the live prefix
        XCTAssertEqual(r.text, "Hello there.")
        XCTAssertTrue(engine.entries().contains("tail@\(live)"))
        // A later attempt, with the fault gone, succeeds.
        engine.failStageAtBatch = nil
        await backend.prepare(dictionary: ["Sotto", String(repeating: "D", count: 600)])
        XCTAssertEqual(engine.entries().filter { $0 == "commit" }.count, 1)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sawFailure = false
    func add(_ event: ModelBackendEvent) { if case .failed = event { lock.withLock { sawFailure = true } } }
    var failed: Bool { lock.withLock { sawFailure } }
}
