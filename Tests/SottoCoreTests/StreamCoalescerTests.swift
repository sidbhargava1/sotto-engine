// CO-xx ids per docs/phase1-test-scenarios.md.
import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class StreamCoalescerTests: XCTestCase {
    func makeStream(_ steps: [(String, Duration)], fail: Error? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for (text, delay) in steps {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    continuation.yield(text)
                }
                if let fail {
                    continuation.finish(throwing: fail)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    func collect(_ stream: AsyncThrowingStream<CoalescedEvent, Error>) async -> ([CoalescedEvent], Error?) {
        var events: [CoalescedEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    // MARK: CO-01 — flushes at ~50ms ticks even with no word boundary

    func test_CO01_flushesOnTickWithNoWordBoundary() async {
        let steps = (0..<20).map { ("x\($0)", Duration.milliseconds($0 == 0 ? 0 : 5)) } // no spaces, ever
        let source = makeStream(steps)
        let config = CoalescerConfig(flushInterval: .milliseconds(30), firstTokenTimeout: .milliseconds(500), stallTimeout: .milliseconds(500))
        let (events, error) = await collect(StreamCoalescer.coalesce(source, config: config))
        XCTAssertNil(error)
        let chunks = events.compactMap { if case .chunk(let t) = $0 { return t } else { return nil } }
        XCTAssertGreaterThan(chunks.count, 1, "a 100ms+ stream with a 30ms tick must flush more than once even without a boundary")
    }

    // MARK: CO-02 — a completed word boundary flushes immediately, not held to the timer

    func test_CO02_wordBoundaryFlushesBeforeTimer() async {
        let source = makeStream([("hello world ", .zero)])
        let config = CoalescerConfig(flushInterval: .seconds(5), firstTokenTimeout: .seconds(5), stallTimeout: .seconds(5))
        let start = ContinuousClock.now
        let (events, _) = await collect(StreamCoalescer.coalesce(source, config: config))
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(500), "boundary flush must not wait for the 5s timer")
        XCTAssertTrue(events.contains(.chunk("hello world ")))
    }

    // MARK: CO-03 — mid-stream stall triggers `.stalled`, not an indefinite hang

    func test_CO03_midStreamStallTriggersStalled() async {
        let source = makeStream([("first ", .zero), ("second", .milliseconds(300))])
        let config = CoalescerConfig(flushInterval: .milliseconds(20), firstTokenTimeout: .milliseconds(500), stallTimeout: .milliseconds(80))
        let (events, _) = await collect(StreamCoalescer.coalesce(source, config: config))
        XCTAssertTrue(events.contains(.stalled))
    }

    // MARK: CO-04 — throw after partial flush keeps what flushed, no rollback

    func test_CO04_throwAfterPartialFlushKeepsPriorChunks() async {
        let source = makeStream([("one ", .zero), ("two ", .milliseconds(5))], fail: FakeError(label: "backend-died"))
        let config = CoalescerConfig(flushInterval: .milliseconds(20), firstTokenTimeout: .milliseconds(200), stallTimeout: .milliseconds(200))
        let (events, error) = await collect(StreamCoalescer.coalesce(source, config: config))
        XCTAssertNotNil(error)
        let chunks = events.compactMap { if case .chunk(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(chunks.joined(), "one two ")
    }

    // MARK: CO-05 — RawBackend flows through the same coalescer path, not a bypass

    func test_CO05_rawBackendSharesCoalescerPath() async {
        let request = CleanupRequest(rawTranscript: "  raw   text  ", dictionary: [], targetContext: makeTestContext())
        let stream = RawBackend().clean(request)
        let (events, error) = await collect(StreamCoalescer.coalesce(stream))
        XCTAssertNil(error)
        let chunks = events.compactMap { if case .chunk(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(chunks.joined(), "raw text")
    }

    // MARK: CO-06 — a new utterance's coalescer is independent; nothing leaks across instances

    func test_CO06_newCoalescerInstanceStartsClean() async {
        let first = makeStream([("stale", .zero)])
        let config = CoalescerConfig(flushInterval: .milliseconds(10), firstTokenTimeout: .milliseconds(50), stallTimeout: .milliseconds(50))
        _ = await collect(StreamCoalescer.coalesce(first, config: config))

        let second = makeStream([("fresh", .zero)])
        let (events, _) = await collect(StreamCoalescer.coalesce(second, config: config))
        let chunks = events.compactMap { if case .chunk(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(chunks.joined(), "fresh")
    }

    func test_CO07_wholeModeEmitsOneChunkAtStreamEnd() async throws {
        let source = AsyncThrowingStream<String, Error> { c in
            c.yield("Send "); c.yield("it "); c.yield("Wednesday."); c.finish()
        }
        var events: [CoalescedEvent] = []
        for try await e in StreamCoalescer.coalesce(source, config: .init(delivery: .whole, flushInterval: .milliseconds(5))) {
            events.append(e)
        }
        XCTAssertEqual(events, [.chunk("Send it Wednesday.")])
    }

    func test_CO07b_wholeModePreservesNewlines() async throws {
        let source = AsyncThrowingStream<String, Error> { c in
            for t in ["Notes", ":\n", "1. A", "\n", "2. B"] { c.yield(t) }
            c.finish()
        }
        var events: [CoalescedEvent] = []
        for try await e in StreamCoalescer.coalesce(source, config: .init(delivery: .whole, flushInterval: .milliseconds(5))) {
            events.append(e)
        }
        XCTAssertEqual(events, [.chunk("Notes:\n1. A\n2. B")])
    }

    func test_CO08_wholeModeStillDetectsStall() async throws {
        let source = AsyncThrowingStream<String, Error> { c in
            c.yield("Send ")
            Task { try? await Task.sleep(for: .milliseconds(200)); c.yield("never"); c.finish() }
        }
        var events: [CoalescedEvent] = []
        for try await e in StreamCoalescer.coalesce(source, config: .init(delivery: .whole, flushInterval: .milliseconds(5), stallTimeout: .milliseconds(40))) {
            events.append(e)
            if e == .stalled { break }
        }
        XCTAssertEqual(events.first, .stalled)
    }
}
