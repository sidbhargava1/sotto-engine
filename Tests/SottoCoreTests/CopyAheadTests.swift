import XCTest
@testable import SottoCore
@testable import SottoCoreTestSupport

final class CopyAheadTests: XCTestCase {
    private let eog: Int32 = 999
    private func settings(lookup: Int = 2, length: Int = 6) -> CopyAhead.Settings { CopyAhead.Settings(lookup: lookup, length: length) }

    // MARK: drafting

    func test_draftCopiesWhatFollowsTheLastGeneratedTokens() {
        var cursor = 0
        let d = CopyAhead.draft(source: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], generated: [9, 3, 4], settings: settings(length: 4), cursor: &cursor)
        XCTAssertEqual(d, [5, 6, 7, 8])
        XCTAssertEqual(cursor, 4)
    }

    func test_draftIsEmptyWithoutAMatchOrEnoughTokens() {
        var cursor = 0
        XCTAssertEqual(CopyAhead.draft(source: [1, 2, 3, 4], generated: [7, 8], settings: settings(), cursor: &cursor), [])
        XCTAssertEqual(CopyAhead.draft(source: [1, 2, 3, 4], generated: [3], settings: settings(), cursor: &cursor), [])
        XCTAssertEqual(CopyAhead.draft(source: [1, 2, 3, 4], generated: [3, 4], settings: settings(), cursor: &cursor), [], "a match at the very end has nothing to copy")
        XCTAssertEqual(cursor, 0)
    }

    func test_draftNeverCopiesBackwardsPastTheCursor() {
        var cursor = 6
        // [1,2] occurs at 0 and 6; the earlier one is behind the cursor.
        let d = CopyAhead.draft(source: [1, 2, 3, 4, 5, 5, 1, 2, 8, 9], generated: [1, 2], settings: settings(length: 2), cursor: &cursor)
        XCTAssertEqual(d, [8, 9])
    }

    func test_draftFallsBackToAnEarlierMatchWhenNothingLiesAhead() {
        var cursor = 8
        let d = CopyAhead.draft(source: [1, 2, 3, 4, 0, 0, 0, 0, 5, 5, 5], generated: [1, 2], settings: settings(length: 2), cursor: &cursor)
        XCTAssertEqual(d, [3, 4])
        XCTAssertEqual(cursor, 2)
    }

    func test_draftIsCappedAtLengthAndAtTheEndOfTheSource() {
        var cursor = 0
        XCTAssertEqual(CopyAhead.draft(source: [1, 2, 3, 4, 5], generated: [1, 2], settings: settings(length: 2), cursor: &cursor), [3, 4])
        cursor = 0
        XCTAssertEqual(CopyAhead.draft(source: [1, 2, 3, 4, 5], generated: [1, 2], settings: settings(length: 6), cursor: &cursor), [3, 4, 5])
    }

    func test_disabledDraftsNothing() {
        var cursor = 0
        var off = settings(); off.enabled = false
        XCTAssertEqual(CopyAhead.draft(source: [1, 2, 3, 4], generated: [1, 2], settings: off, cursor: &cursor), [])
        XCTAssertEqual(off.headroom, 0)
        XCTAssertEqual(settings(length: 6).headroom, 6)
    }

    // MARK: verification (forced rejection)

    /// The model's greedy continuation `truth`; `sample(i)` is truth[i] as long as the batch was
    /// built from the same prefix, which is what the engine guarantees by only keeping agreed tokens.
    private func resolve(draft: [Int32], truth: [Int32]) -> CopyAhead.Resolution {
        CopyAhead.resolve(draft: draft, sample: { truth[$0] }, isEnd: { $0 == self.eog })
    }

    func test_allAcceptedAddsTheBonusToken() {
        let r = resolve(draft: [10, 11, 12], truth: [10, 11, 12, 13])
        XCTAssertEqual(r, .init(emitted: [10, 11, 12, 13], accepted: 3, ended: false))
    }

    func test_rejectionAtIndexZeroEmitsTheModelsToken() {
        let r = resolve(draft: [99, 11, 12], truth: [10, 0, 0, 0])
        XCTAssertEqual(r, .init(emitted: [10], accepted: 0, ended: false))
    }

    func test_rejectionInTheMiddleKeepsTheAgreedPrefix() {
        let r = resolve(draft: [10, 11, 99, 13], truth: [10, 11, 12, 0, 0])
        XCTAssertEqual(r, .init(emitted: [10, 11, 12], accepted: 2, ended: false))
    }

    func test_rejectionAtTheLastDraftTokenStillGainsOne() {
        let r = resolve(draft: [10, 11, 99], truth: [10, 11, 12, 0])
        XCTAssertEqual(r, .init(emitted: [10, 11, 12], accepted: 2, ended: false))
    }

    func test_endOfTurnInsideTheDraftStopsThere() {
        // The draft copied past the answer into the end token; the model agrees at index 2.
        let r = resolve(draft: [10, 11, eog, 7, 7], truth: [10, 11, eog, 0, 0, 0])
        XCTAssertEqual(r, .init(emitted: [10, 11, eog], accepted: 2, ended: true))
    }

    func test_endOfTurnWhereTheDraftContinuedDropsTheRest() {
        let r = resolve(draft: [10, 11, 12, 13], truth: [10, eog, 0, 0, 0])
        XCTAssertEqual(r, .init(emitted: [10, eog], accepted: 1, ended: true))
    }

    func test_endOfTurnAtIndexZero() {
        XCTAssertEqual(resolve(draft: [10], truth: [eog, 0]), .init(emitted: [eog], accepted: 0, ended: true))
    }

    func test_emptyDraftIsOneNormalStep() {
        XCTAssertEqual(resolve(draft: [], truth: [5]), .init(emitted: [5], accepted: 0, ended: false))
    }

    /// Whatever the draft, the emitted tokens are a prefix of what plain greedy would produce, and the
    /// kept KV (previous + accepted) is exactly the tokens before the last emitted one.
    func test_anyDraftEmitsAPrefixOfGreedy() {
        var rng = SystemRandomNumberGenerator()
        let truth: [Int32] = (0..<40).map { Int32($0) + 100 } + [eog] + [0, 0, 0, 0, 0, 0, 0, 0]
        for _ in 0..<2000 {
            let at = Int.random(in: 0..<40, using: &rng)
            let len = Int.random(in: 0...7, using: &rng)
            var draft = (0..<len).map { truth[at + $0] }
            if len > 0, Bool.random(using: &rng) { draft[Int.random(in: 0..<len, using: &rng)] = -1 }
            let r = CopyAhead.resolve(draft: draft, sample: { truth[at + $0] }, isEnd: { $0 == self.eog })
            XCTAssertEqual(r.emitted, Array(truth[at..<(at + r.emitted.count)]))
            XCTAssertEqual(r.accepted, r.emitted.count - 1)
            XCTAssertLessThanOrEqual(r.emitted.count, len + 1)
        }
    }

    // MARK: bursts and the stall guard

    private func stream(_ steps: [(String, Duration)]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            Task {
                for (text, delay) in steps { if delay > .zero { try? await Task.sleep(for: delay) }; c.yield(text) }
                c.finish()
            }
        }
    }

    private func events(_ source: AsyncThrowingStream<String, Error>, stall: Duration) async throws -> [CoalescedEvent] {
        let config = CoalescerConfig(flushInterval: .milliseconds(30), firstTokenTimeout: .seconds(5), stallTimeout: stall)
        var out: [CoalescedEvent] = []
        for try await e in StreamCoalescer.coalesce(source, config: config) { out.append(e) }
        return out
    }

    /// Seven tokens at once then a pause shorter than the stall timeout, repeated: delivered whole, no stall.
    func test_burstsOfSevenWithinTheStallTimeoutDoNotStall() async throws {
        var steps: [(String, Duration)] = []
        for b in 0..<4 { for k in 0..<7 { steps.append(("w\(b)\(k) ", k == 0 ? .milliseconds(b == 0 ? 0 : 150) : .zero)) } }
        let ev = try await events(stream(steps), stall: .milliseconds(400))
        XCTAssertFalse(ev.contains(.stalled))
        let text = ev.compactMap { if case .chunk(let t) = $0 { t } else { nil } }.joined()
        XCTAssertEqual(text, steps.map(\.0).joined())
    }

    func test_aPauseLongerThanTheStallTimeoutAfterABurstStillStalls() async throws {
        let steps: [(String, Duration)] = (0..<7).map { ("w\($0) ", .zero) } + [("late ", .milliseconds(700))]
        let ev = try await events(stream(steps), stall: .milliseconds(300))
        XCTAssertTrue(ev.contains(.stalled))
    }
}
