// Real-model checks of copy-ahead decoding. Skipped unless SOTTO_LLM_MODEL names a GGUF (CI has no weights):
//   SOTTO_LLM_MODEL=<gguf> [SOTTO_EVAL_TRANSCRIPTS=<dir of .txt>] swift test --filter CopyAheadModelTests
import Darwin
import XCTest
import SottoCore
@testable import SottoEngine

final class CopyAheadModelTests: XCTestCase {
    private static var model: URL? { ProcessInfo.processInfo.environment["SOTTO_LLM_MODEL"].map { URL(fileURLWithPath: $0) } }

    private static let builtIn = [
        "um can you send me the latest numbers for the quarterly report before the meeting tomorrow morning please thanks",
        "so i looked at the pull request this morning and um the main change is fine but i think we should split the migration into two steps first add the column and then backfill it in a separate job so we can roll back",
        "okay so the plan for next week is pretty simple i think on monday we freeze the branch and run the full regression suite um then on tuesday we fix whatever breaks and write up the release notes and on wednesday we send the build to the beta testers uh the only real risk is the audio permission flow because it behaves differently on older machines so i want somebody to test that on a clean install",
        "send it tuesday no wait wednesday to the whole team",
        // The two golden batch transcripts (Tests/SottoCoreTests/Golden/stream-hypotheses.txt), STT-cased.
        "Okay so send it Tuesday no wait Wednesday to the whole team and make sure you see C Sit and Klaus on the email so they have full visibility into the release timeline and can flag any blockers early before we actually ship it out to everyone on Friday.",
        "Um can you send that file over to me before lunch today please because I need it for the call.",
    ]

    /// Built-in texts (incl. the golden batch transcripts), and every .txt in SOTTO_EVAL_TRANSCRIPTS (not the .expected ones).
    private func transcripts() throws -> [String] {
        var all = Self.builtIn
        for dir in (ProcessInfo.processInfo.environment["SOTTO_EVAL_TRANSCRIPTS"] ?? "").split(separator: ":").map(String.init) {  // colon-separated dirs
            let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".txt") && !$0.hasSuffix(".expected.txt") }.sorted()
            for f in files { all.append(try String(contentsOfFile: dir + "/" + f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return all
    }

    private func request(_ text: String) -> CleanupRequest {
        CleanupRequest(rawTranscript: text, dictionary: ["Sotto", "WalletTree (wallet tree)"], targetContext: TargetContext(bundleID: "com.example.app", isTerminalClass: false, elementToken: nil, accessibilityGranted: true))
    }

    private func loaded() throws -> LlamaEngine {
        let url = try XCTUnwrap(Self.model, "set SOTTO_LLM_MODEL")
        let engine = LlamaEngine(modelURL: url, contextSize: 3072)
        try engine.load()
        return engine
    }

    /// Prefix + tail the way the backend builds them; returns where the tail starts.
    private func prime(_ engine: LlamaEngine, _ text: String) throws -> Int {
        let prompt = PromptBuilder.build(request(text))
        let prefix = try engine.tokenize(ChatML.prefix(prompt.prefix))
        try engine.resetAndPrefill(prefix)
        let tail = try engine.tokenize(ChatML.tail(prompt.tail))
        try engine.replaceTail(tail, after: prefix.count)
        return prefix.count
    }

    private func run(_ engine: LlamaEngine, _ text: String, stopAfter: Int = 600) throws -> (text: String, tokens: [Int32], kv: Int) {
        _ = try prime(engine, text)
        var out = ""
        var n = 0
        while n < stopAfter, let piece = try engine.sampleNext() { out += piece; n += 1 }
        return (out, engine.generated, engine.kvLength)
    }

    override func setUpWithError() throws { if Self.model == nil { throw XCTSkip("set SOTTO_LLM_MODEL") } }

    func test_samplerHasNoStateBetweenPositions() throws {
        let engine = try loaded(); defer { engine.unload() }
        XCTAssertTrue(engine.samplerIsStatelessGreedy)
    }

    /// Spec on = spec off, token for token, for every transcript, three times, with real drafts.
    func test_outputIsIdenticalToPlainGreedy() throws {
        let engine = try loaded(); defer { engine.unload() }
        var drafted = 0, accepted = 0
        for text in try transcripts() {
            engine.speculation.enabled = false
            let reference = try run(engine, text)
            for _ in 0..<3 {
                engine.speculation.enabled = true
                let before = (engine.draftedTokens, engine.acceptedTokens)
                let r = try run(engine, text)
                drafted += engine.draftedTokens - before.0; accepted += engine.acceptedTokens - before.1
                XCTAssertEqual(r.text, reference.text, "differs for: \(text.prefix(60))")
                XCTAssertEqual(r.tokens, reference.tokens)
                XCTAssertEqual(r.kv, reference.kv, "KV length after the run")
            }
        }
        print("COPY_AHEAD_IDENTITY transcripts=\(try transcripts().count) x3 drafted=\(drafted) accepted=\(accepted)")
        XCTAssertGreaterThan(accepted, 0, "speculation never fired")
    }

    /// Drafts built from the true continuation, corrupted at chosen places. The output and KV must not change.
    func test_forcedRejectionsKeepOutputAndKVIdentical() throws {
        let engine = try loaded(); defer { engine.unload() }
        let text = Self.builtIn[1]
        engine.speculation.enabled = false
        let reference = try run(engine, text)
        let end = try engine.tokenize([PromptSegment("<|im_end|>", special: true)])[0]
        let truth = reference.tokens
        let wrong: Int32 = truth.max()! + 1
        enum Spot { case first, middle, last, none, endInside, endBeyond }
        func override(_ spot: Spot, length: Int) -> ([Int32]) -> [Int32] {
            { generated in
                let at = generated.count
                guard at < truth.count else { return [] }
                var d = Array(truth[at..<min(at + length, truth.count)])
                // Past the real end the draft continues with the end token and junk.
                if spot == .endInside || spot == .endBeyond, at + length >= truth.count { d += [end, 1, 2] }
                guard !d.isEmpty else { return [] }
                switch spot {
                case .first: d[0] = wrong
                case .middle: d[d.count / 2] = wrong
                case .last: d[d.count - 1] = wrong
                case .none, .endInside, .endBeyond: break
                }
                return d
            }
        }
        engine.speculation.enabled = true
        for spot in [Spot.first, .middle, .last, .none, .endInside, .endBeyond] {
            for length in [1, 3, 7] {
                engine.draftOverride = override(spot, length: length)
                let before = engine.speculativeSteps
                let r = try run(engine, text)
                XCTAssertEqual(r.text, reference.text, "\(spot) x\(length)")
                XCTAssertEqual(r.tokens, reference.tokens, "\(spot) x\(length)")
                XCTAssertEqual(r.kv, reference.kv, "KV length \(spot) x\(length)")
                XCTAssertGreaterThan(engine.speculativeSteps, before)
            }
        }
        engine.draftOverride = nil
    }

    /// Stop mid-burst (the consumer cancelled), start another request: no leftover tokens, no stale KV.
    func test_cancellingMidBurstLeavesNothingBehind() throws {
        let engine = try loaded(); defer { engine.unload() }
        let a = Self.builtIn[1], b = Self.builtIn[2]
        engine.speculation.enabled = false
        let reference = try run(engine, b)
        engine.speculation.enabled = true
        for stop in [1, 2, 3, 5, 9] {
            _ = try prime(engine, a)
            for _ in 0..<stop { _ = try engine.sampleNext() }
            let r = try run(engine, b)  // replaceTail resets the queue and the position
            XCTAssertEqual(r.text, reference.text, "after stopping at \(stop)")
            XCTAssertEqual(r.kv, reference.kv)
        }
    }

    func test_bursts_neverExceedTheDraftLengthPlusOne() throws {
        let engine = try loaded(); defer { engine.unload() }
        _ = try run(engine, Self.builtIn[2])
        XCTAssertLessThanOrEqual(engine.speculationHeadroom, 6)
        XCTAssertGreaterThan(engine.speculativeSteps, 0)
        XCTAssertLessThanOrEqual(engine.draftedTokens, engine.speculativeSteps * 6)
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func test_speculationCostsLessThan20MB() throws {
        let engine = try loaded(); defer { engine.unload() }
        let long = Self.builtIn[2] + " " + Self.builtIn[1]
        engine.speculation.enabled = false
        _ = try run(engine, long); _ = try run(engine, long)
        let off = footprintMB()
        engine.speculation.enabled = true
        _ = try run(engine, long); _ = try run(engine, long)
        let on = footprintMB()
        print("COPY_AHEAD_MEMORY footprint off=\(off) MB on=\(on) MB delta=\(on - off) MB")
        XCTAssertLessThan(on - off, 20)
    }

    func test_offSwitchNeverDrafts() throws {
        let engine = try loaded(); defer { engine.unload() }
        engine.speculation.enabled = false
        let r = try run(engine, Self.builtIn[2])
        XCTAssertEqual(engine.speculativeSteps, 0)
        XCTAssertFalse(r.text.isEmpty)
        XCTAssertEqual(CopyAhead.Settings.fromEnvironment(["SOTTO_SPECULATION": "0"]).enabled, false)
        XCTAssertEqual(CopyAhead.Settings.fromEnvironment([:]).enabled, true)
    }

    /// Request to last piece through the real backend, by the plan's word buckets, speculation off vs on.
    /// Prints COPY_AHEAD_LATENCY lines; asserts nothing (timing is for the PR, not a gate).
    func test_latencyByBucket() async throws {
        guard ProcessInfo.processInfo.environment["SOTTO_EVAL_TRANSCRIPTS"] != nil else { throw XCTSkip("set SOTTO_EVAL_TRANSCRIPTS") }
        let engine = LlamaEngine(modelURL: try XCTUnwrap(Self.model), contextSize: 3072)
        let backend = ModelCleanupBackend(engine: engine) { _ in }
        try await backend.load(dictionary: ["Sotto", "WalletTree (wallet tree)"])
        func pct(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int((p * Double(s.count - 1)).rounded()))] }
        let texts = try transcripts()
        for enabled in [false, true] {
            engine.speculation.enabled = enabled
            var buckets: [String: [Double]] = [:]
            for _ in 0..<3 {
                for t in texts {
                    let start = ContinuousClock.now
                    for try await _ in backend.clean(request(t)) {}
                    let ms = (ContinuousClock.now - start) / .milliseconds(1)
                    let w = t.split(separator: " ").count
                    buckets[w <= 20 ? "<=20" : w <= 45 ? "21-45" : ">45", default: []].append(Double(ms))
                }
            }
            for b in ["<=20", "21-45", ">45"] {
                let v = buckets[b] ?? []
                print("COPY_AHEAD_LATENCY speculation=\(enabled) bucket=\(b) n=\(v.count) p50=\(Int(pct(v, 0.5))) p95=\(Int(pct(v, 0.95)))")
            }
        }
    }
}
