// `--dry-run`: exercises the whole pipeline without typing into, or copying from, the Mac
// in use. Logs lengths only: dictated text never reaches the unified log.
import SottoCore
import os

public struct DryRunInjector: TextInjecting, ClipboardWriting {
    private let log: Logger

    public init(log: LogSubsystem) { self.log = log.logger("dry-run") }

    public func append(_ text: String, to context: TargetContext) async -> InjectionOutcome {
        log.info("would inject \(text.count, privacy: .public) chars")
        return .success
    }

    public func copy(_ text: String) async {
        log.info("would copy \(text.count, privacy: .public) chars")
    }
}
