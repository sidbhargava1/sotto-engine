// Real-model check that the 4B cleanup model carries placeholders through exactly once. Skipped
// unless SOTTO_LLM_MODEL names a GGUF (CI has no weights):
//   SOTTO_LLM_MODEL=<gguf> swift test --filter ProtectedModelTests
import XCTest
import SottoCore
@testable import SottoEngine

final class ProtectedModelTests: XCTestCase {
    static let phrases = [
        ProtectedPhrase(spoken: "my calendar link", text: "https://cal.com/me"),
        ProtectedPhrase(spoken: "standup template", text: "Yesterday:\nToday:\nBlockers: none"),
        ProtectedPhrase(spoken: "review sign off", text: "Looks good to me."),
    ]
    static let speeches = [
        "sure here's my calendar link grab any slot that works",
        "um so can you send them my calendar link and also the standup template before friday",
        "hey priya thanks for the review sign off no wait the standup template is what i meant",
        "my calendar link",
        "okay so first review sign off second my calendar link third the standup template",
        "i was thinking we could meet tuesday or wednesday so here's my calendar link and if neither works just ping me",
        "please use my calendar link to book thirty minutes uh the standup template is in the channel",
        "what's my calendar link again",
        "send the standup template to dana and the review sign off to priya",
        "yeah my calendar link is the one you want",
    ]

    func test_placeholdersSurviveTheModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOTTO_LLM_MODEL"] else { throw XCTSkip("set SOTTO_LLM_MODEL") }
        let backend = ModelCleanupBackend(engine: LlamaEngine(modelURL: URL(fileURLWithPath: path), contextSize: 3072)) { _ in }
        try await backend.load(dictionary: [])
        let context = TargetContext(bundleID: "com.example.app", isTerminalClass: false, elementToken: nil, accessibilityGranted: true)
        let rounds = Int(ProcessInfo.processInfo.environment["SOTTO_ROUNDS"] ?? "") ?? 1
        var ok = 0, total = 0
        for _ in 0..<rounds {
            for speech in Self.speeches {
                let p = try XCTUnwrap(ProtectedText(speech, phrases: Self.phrases))
                let request = CleanupRequest(rawTranscript: p.masked, dictionary: [], targetContext: context, protectedTokens: p.tokens)
                var out = ""
                do { for try await piece in backend.clean(request) { out += piece } } catch { out += "[\(error)]" }
                let landed = p.restoring(out)
                total += 1
                if p.isOnlyProtected { ok += 1 } else if landed != nil { ok += 1 }
                print("PROTECTED \(landed != nil ? "ok  " : "LOST") in: \(p.masked)\n          out: \(out.replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
        print("PROTECTED SUMMARY \(ok)/\(total)")
        await backend.shutdown()
        XCTAssertEqual(ok, total)
    }
}
