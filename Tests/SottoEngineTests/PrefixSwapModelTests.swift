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

    func test_swapMatchesAFreshPrefillAndKeepsServing() async throws {
        guard let url = Self.model else { throw XCTSkip("set SOTTO_LLM_MODEL") }
        let old = Self.terms(60), new = Self.terms(60) + ["Zorblax (zorb lacks)"]
        let backend = LlamaBackend.make(modelURL: url, log: LogSubsystem("sotto-engine-tests"))
        try await backend.load(dictionary: old)
        let reference = LlamaBackend.make(modelURL: url, log: LogSubsystem("sotto-engine-tests"))
        try await reference.load(dictionary: new)
        let speech = "um so I talked to zorb lacks about the word smith 3 ford release and we should ship it on friday no wait monday"

        let start = ContinuousClock.now
        let finished = Mutex(false)
        let build = Task { await backend.prepare(dictionary: new); finished.withLock { $0 = true } }
        var during: [Int] = []
        while !finished.withLock({ $0 }), (ContinuousClock.now - start) < .seconds(10) {
            let r = await collect(backend, request(speech, new))  // mismatched until the swap
            during.append(r.ttftMs)
        }
        await build.value
        let buildMs = Int((ContinuousClock.now - start) / .milliseconds(1))
        let swapped = await collect(backend, request(speech, new))
        let fresh = await collect(reference, request(speech, new))
        print("SWAP build \(buildMs) ms; ttft of requests during the build (ms): \(during); after swap \(swapped.ttftMs) ms")
        XCTAssertEqual(swapped.text, fresh.text, "a swapped prefix decodes like a freshly prefilled one")
        XCTAssertFalse(swapped.text.contains("["))
        await backend.shutdown()
        await reference.shutdown()
    }
}
