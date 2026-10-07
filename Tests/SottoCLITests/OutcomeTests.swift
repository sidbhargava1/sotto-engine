// CLI.md "Exit status" and "Degraded results", row by row, from the states a session emits.
import SottoCore
@testable import SottoCLI
import XCTest

final class OutcomeTests: XCTestCase {
    private func evaluate(_ states: [SessionState], _ output: OutputMode = .stdout, text: String? = "Hello.") -> Outcome {
        Outcome.evaluate(states: states, output: output, text: text)
    }

    func test_cleanResultIsZeroWithNoWarnings() {
        // stdout delivers through the session's clipboard slot, so copiedNoTarget is the normal path.
        let outcome = evaluate([.recording, .transcribing, .cleaning, .degraded(.copiedNoTarget), .idle])
        XCTAssertEqual(outcome, Outcome(code: .ok))
    }

    func test_rawFallbackIsZeroWithAWarning() {
        let outcome = evaluate([.recording, .transcribing, .cleaning, .degraded(.rawTyped), .idle])
        XCTAssertEqual(outcome.code, .ok)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("raw transcript"))
    }

    func test_truncatedCleanupIsZeroWithAWarning() {
        let outcome = evaluate([.transcribing, .degraded(.cleanupTruncated), .idle])
        XCTAssertEqual(outcome.code, .ok)
        XCTAssertEqual(outcome.warnings.count, 1)
    }

    func test_nothingRecognisedIsOne() {
        for reason in [ErrorReason.sttFailed, .silentInput(device: "USB Mic"), .silentInput(device: nil), .micLost] {
            let outcome = evaluate([.recording, .transcribing, .error(reason), .idle], text: "")
            XCTAssertEqual(outcome.code, .nothingRecognised, "\(reason)")
            XCTAssertNotNil(outcome.error)
        }
        XCTAssertTrue(evaluate([.error(.silentInput(device: "USB Mic")), .idle], text: "").error!.contains("USB Mic"))
    }

    func test_emptyOutputIsOneEvenWithoutAnErrorState() {
        XCTAssertEqual(evaluate([.transcribing, .degraded(.copiedNoTarget), .idle], text: "  \n").code, .nothingRecognised)
    }

    func test_micDeniedIsSeventySeven() {
        XCTAssertEqual(evaluate([.error(.micDenied), .idle], text: "").code, .noPermission)
    }

    func test_modelMissingIsSixtyNine() {
        XCTAssertEqual(evaluate([.transcribing, .error(.modelMissing), .idle], text: "").code, .unavailable)
    }

    func test_injectWarnsWhenTheResultWentToTheClipboard() {
        let noField = evaluate([.transcribing, .degraded(.copiedNoTarget), .idle], .inject, text: nil)
        XCTAssertEqual(noField.code, .ok)
        XCTAssertTrue(noField.warnings.contains { $0.contains("clipboard") })
        let typed = evaluate([.transcribing, .cleaning, .injecting, .idle], .inject, text: nil)
        XCTAssertEqual(typed, Outcome(code: .ok))
    }

    /// CLI.md: missing Accessibility with --inject is not an error.
    func test_noAccessibilityIsZeroWithAClipboardWarning() {
        let outcome = evaluate([.transcribing, .degraded(.copiedNoTarget), .idle], .clipboard)
        XCTAssertEqual(outcome.code, .ok)
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("Accessibility"))
    }

    func test_exitCodesMatchTheTable() {
        XCTAssertEqual(
            [ExitCode.ok, .nothingRecognised, .usage, .noInput, .unavailable, .noPermission, .cancelled].map(\.rawValue),
            [0, 1, 64, 66, 69, 77, 130]
        )
    }
}
