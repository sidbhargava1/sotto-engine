// What a finished run means for the exit code and stderr (CLI.md "Exit status", "Degraded
// results"), read from the session's state sequence. Pure, so every row is unit-tested.
import SottoCore

/// Where the result goes: stdout, the focused app, or the clipboard when Accessibility is off.
enum OutputMode: Equatable, Sendable {
    case stdout
    case inject
    case clipboard
}

struct Outcome: Equatable, Sendable {
    var code: ExitCode
    /// Printed whatever `--quiet` says.
    var error: String?
    /// Suppressed by `--quiet`.
    var warnings: [String] = []

    /// `text`: what reached the output sink (stdout or the no-Accessibility clipboard); nil when
    /// the session typed it into an app itself.
    static func evaluate(states: [SessionState], output: OutputMode, text: String?) -> Outcome {
        for state in states {
            guard case .error(let reason) = state else { continue }
            switch reason {
            case .micDenied:
                return Outcome(code: .noPermission, error: "microphone access denied; allow it for this terminal in System Settings → Privacy & Security → Microphone")
            case .modelMissing:
                return Outcome(code: .unavailable, error: "speech model missing; re-run with --download")
            case .micLost:
                return Outcome(code: .nothingRecognised, error: "no audio input available")
            case .silentInput(let device):
                return Outcome(code: .nothingRecognised, error: "nothing recognised: \(device ?? "the input") delivered only silence")
            case .sttFailed, .undoRefused:
                return Outcome(code: .nothingRecognised, error: "nothing recognised")
            }
        }
        if let text, text.allSatisfy(\.isWhitespace) {
            return Outcome(code: .nothingRecognised, error: "nothing recognised")
        }

        var warnings: [String] = []
        for state in states {
            guard case .degraded(let reason) = state else { continue }
            switch (reason, output) {
            case (.rawTyped, _):
                warnings.append("cleanup failed or stalled; output is the raw transcript")
            case (.cleanupTruncated, _):
                warnings.append("cleanup hit its output limit; the result may be cut short")
            case (.injectionUnverified, _):
                warnings.append("the app accepted the text but it couldn't be confirmed")
            // stdout and the clipboard mode deliver through the session's clipboard slot on purpose.
            case (.copiedNoTarget, .inject):
                warnings.append("no text field had focus; the result is on the clipboard")
            case (.copiedNoAX, .inject):
                warnings.append("Accessibility is off; the result is on the clipboard")
            case (.copiedNoTarget, _), (.copiedNoAX, _):
                break
            }
        }
        if output == .clipboard {
            warnings.append("Accessibility permission is missing; the result was copied to the clipboard instead")
        }
        return Outcome(code: .ok, warnings: warnings)
    }
}
