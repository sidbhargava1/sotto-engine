// Real-model check of the staged prefix swap and the n_ctx budget. Skipped unless SOTTO_LLM_MODEL
// names a GGUF (CI has no weights): SOTTO_LLM_MODEL=<gguf> swift test --filter PrefixSwapModelTests
import Synchronization
import XCTest
import SottoCore
@testable import SottoEngine

final class PrefixSwapModelTests: XCTestCase {
    private static var model: URL? { ProcessInfo.processInfo.environment["SOTTO_LLM_MODEL"].map { URL(fileURLWithPath: $0) } }

    /// Names with a heard-as variant each, the shape of a real dictionary.
    private static func terms(_ n: Int) -> [String] {
        (0..<n).map { "Wordsmith\($0)ford (word smith \($0) ford, wordsmith \($0))" }
    }

    private func request(_ text: String, _ dictionary: [String]) -> CleanupRequest {
        CleanupRequest(rawTranscript: text, dictionary: dictionary, targetContext: TargetContext(bundleID: "com.example.app", isTerminalClass: false, elementToken: nil, accessibilityGranted: true))
    }

    private func collect(_ backend: ModelCleanupBackend, _ r: CleanupRequest) async -> (text: String, ttftMs: Int) {
        let start = ContinuousClock.now
        var first: Int?
        var text = ""
        do {
            for try await piece in backend.clean(r) {
                if first == nil { first = Int((ContinuousClock.now - start) / .milliseconds(1)) }
                text += piece
            }
        } catch { text += "[\(error)]" }
        return (text, first ?? -1)
    }

    /// SOTTO_LLM_DICT: a dictionary file whose lines are measured as entries (one per line).
    func test_contextBudget() throws {
        guard let url = Self.model else { throw XCTSkip("set SOTTO_LLM_MODEL") }
        let engine = LlamaEngine(modelURL: url, contextSize: 3072)
        try engine.load()
        defer { engine.unload() }
        func count(_ dictionary: [String]) throws -> Int { try engine.tokenize(ChatML.prefix(PromptBuilder.prefix(dictionary: dictionary))).count }
        let base = try count([])
        let lines = (ProcessInfo.processInfo.environment["SOTTO_LLM_DICT"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
            .split(separator: "\n").map(String.init)
        var report = "instructions only: \(base) tokens\n"
        guard !lines.isEmpty else { return print("N_CTX_BUDGET\n" + report + "set SOTTO_LLM_DICT for per-entry cost") }
        let full = try count(lines)
        let perEntry = Double(full - base) / Double(lines.count)
        report += "\(lines.count) real entries: prefix \(full) tokens, \(String(format: "%.1f", perEntry)) per entry\n"
        // Worst case: the new entry sorts first, so only the instructions are shared with the live prefix.
        for (label, reserve) in [("3x120-token tail + 64", 3 * 120 + 64), ("the backend's 1024 reserve", Self.reserve)] {
            var n = 0
            while base + Int(Double(n + 1) * perEntry) * 2 + reserve <= 3072 { n += 1 }
            report += "largest dictionary staged in the worst case with \(label): \(n) entries (\(base + Int(Double(n) * perEntry)) tokens); beyond it the backend rebuilds in place\n"
        }
        print("N_CTX_BUDGET\n" + report)
    }

    private static let reserve = ModelCleanupBackend.stagingReserve

    func test_requestsDuringTheBuildMatchTheOldDictionaryAndTheSwapMatchesTheNew() async throws {
        guard let url = Self.model else { throw XCTSkip("set SOTTO_LLM_MODEL") }
        let old = Self.terms(25), new = Self.terms(25) + ["Aardvark (art vark)"]  // sorts first: only the instructions are shared; sized so staging fits the budget
        let engine = LlamaEngine(modelURL: url, contextSize: 3072)
        let backend = ModelCleanupBackend(engine: engine) { _ in }
        try await backend.load(dictionary: old)
        let referenceOld = LlamaBackend.make(modelURL: url, log: LogSubsystem("sotto-engine-tests"))
        try await referenceOld.load(dictionary: old)
        let referenceNew = LlamaBackend.make(modelURL: url, log: LogSubsystem("sotto-engine-tests"))
        try await referenceNew.load(dictionary: new)
        let speech = "um so I talked to art vark about the word smith 3 ford release and we should ship it on friday no wait monday"

        let finished = Mutex(false)
        let build = Task { await backend.prepare(dictionary: new); finished.withLock { $0 = true } }
        var during: [(text: String, ttftMs: Int)] = []
        while !finished.withLock({ $0 }), during.count < 12 {
            let r = await collect(backend, request(speech, new))  // mismatched until the swap
            if engine.swaps == 0 { during.append(r) }  // one that finished after the swap decoded on the new prefix
        }
        await build.value
        // The wrong-KV promise: a request served mid-build is exactly what the old dictionary alone would give.
        let expectedOld = await collect(referenceOld, request(speech, old))
        for (i, r) in during.enumerated() {
            XCTAssertEqual(r.text, expectedOld.text, "request \(i) during the build must decode against the old prefix's full prompt")
        }
        let swapped = await collect(backend, request(speech, new))
        let fresh = await collect(referenceNew, request(speech, new))
        XCTAssertEqual(engine.swaps, 1, "the staged path was taken, not an in-place rebuild")
        print("SWAP requests during build: \(during.count), ttft ms \(during.map(\.ttftMs)); after swap \(swapped.ttftMs) ms")
        XCTAssertFalse(during.isEmpty)
        XCTAssertEqual(swapped.text, fresh.text, "a swapped prefix decodes like a freshly prefilled one")
        XCTAssertFalse(swapped.text.contains("["))
        for b in [backend, referenceOld, referenceNew] { await b.shutdown() }
    }

    /// Decode speed and first-token time on the same requests after a swap (scattered cells) vs after a fresh load.
    func test_swappedPrefixIsAsFastAsAFreshOne() async throws {
        guard let url = Self.model else { throw XCTSkip("set SOTTO_LLM_MODEL") }
        let old = Self.terms(25), new = Self.terms(25) + ["Aardvark (art vark)"]
        let speeches = [
            "um so I talked to art vark about the release and we should ship it on friday no wait monday",
            "hey can you check if the word smith 3 ford build is still failing on startup and let me know what you find because I need to tell the team before the standup tomorrow morning at nine",
            String(repeating: "we met with the vendor and they said the shipment is coming on the eleventh and we should have everything unpacked by the end of that week ", count: 2) + "if nothing else goes wrong",
        ]
        func measure(_ backend: ModelCleanupBackend, _ events: Samples) async -> (ttft: Double, tps: Double) {
            for s in speeches { _ = await collect(backend, request(s, new)) }  // warm
            events.clear()
            for _ in 0..<6 { for s in speeches { _ = await collect(backend, request(s, new)) } }
            let all = events.all
            func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
            return (median(all.map { $0.ttft }), median(all.map { $0.tps }))
        }
        func make(_ events: Samples) -> ModelCleanupBackend {
            ModelCleanupBackend(engine: LlamaEngine(modelURL: url, contextSize: 3072)) { event in
                if case .decoded(_, _, let ttft, let tps) = event, let ttft { events.add(Double(ttft / .milliseconds(1)), tps) }
            }
        }
        var fresh: [(Double, Double)] = [], swapped: [(Double, Double)] = []
        for _ in 0..<3 {  // interleaved so thermal drift hits both
            let fe = Samples(), se = Samples()
            let f = make(fe); try await f.load(dictionary: new)
            fresh.append(await measure(f, fe)); await f.shutdown()
            let we = LlamaEngine(modelURL: url, contextSize: 3072)
            let w = ModelCleanupBackend(engine: we) { event in
                if case .decoded(_, _, let ttft, let tps) = event, let ttft { se.add(Double(ttft / .milliseconds(1)), tps) }
            }
            try await w.load(dictionary: old); await w.prepare(dictionary: new)
            XCTAssertEqual(we.swaps, 1, "measuring a swapped prefix, not an in-place rebuild")
            swapped.append(await measure(w, se)); await w.shutdown()
        }
        func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        let f = (med(fresh.map { $0.0 }), med(fresh.map { $0.1 })), w = (med(swapped.map { $0.0 }), med(swapped.map { $0.1 }))
        print(String(format: "SWAPPERF fresh ttft %.1f ms, %.1f tok/s; swapped ttft %.1f ms, %.1f tok/s; ttft %+.1f%%, tok/s %+.1f%%; per-run fresh %@ swapped %@",
                     f.0, f.1, w.0, w.1, (w.0 / f.0 - 1) * 100, (w.1 / f.1 - 1) * 100, "\(fresh)", "\(swapped)"))
    }
}

private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(ttft: Double, tps: Double)] = []
    func add(_ ttft: Double, _ tps: Double) { lock.withLock { values.append((ttft, tps)) } }
    func clear() { lock.withLock { values.removeAll() } }
    var all: [(ttft: Double, tps: Double)] { lock.withLock { values } }
}
