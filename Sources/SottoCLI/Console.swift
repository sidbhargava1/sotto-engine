// stdout carries only the result; everything else goes to stderr (CLI.md), errors even with -q.
import Darwin
import Foundation
import Synchronization

struct Console: Sendable {
    let quiet: Bool

    static let stderrIsTTY = isatty(STDERR_FILENO) == 1
    static let stdoutIsTTY = isatty(STDOUT_FILENO) == 1

    func status(_ message: String) { if !quiet { Self.stderr("sotto: \(message)\n") } }
    func warn(_ message: String) { if !quiet { Self.stderr("sotto: warning: \(message)\n") } }
    func error(_ message: String) { Self.stderr("sotto: \(message)\n") }

    /// A newline only on a terminal: a piped result must not carry a Return into a shell
    /// (`sotto dictate | pbcopy`, then paste), and `$(…)` would strip it anyway.
    static func result(_ text: String) {
        FileHandle.standardOutput.write(Data((stdoutIsTTY ? text + "\n" : text).utf8))
    }

    static func stdout(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
    static func stderr(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }

    /// Download progress: one rewritten line on a terminal, a line per 10% otherwise.
    func progress(_ label: String) -> DownloadProgress { DownloadProgress(label: label, silent: quiet) }
}

final class DownloadProgress: Sendable {
    private let label: String
    private let silent: Bool
    private let last = Mutex(-1)

    init(label: String, silent: Bool) {
        self.label = label
        self.silent = silent
    }

    var update: @Sendable (Double) -> Void { { [self] in report($0) } }

    private func report(_ fraction: Double) {
        guard !silent else { return }
        let percent = min(100, max(0, Int((fraction * 100).rounded(.down))))
        let step = Console.stderrIsTTY ? percent : percent / 10 * 10
        let changed = last.withLock { seen in
            defer { seen = max(seen, step) }
            return step > seen
        }
        guard changed else { return }
        Console.stderr(Console.stderrIsTTY ? "\rsotto: downloading \(label)… \(percent)%" : "sotto: downloading \(label)… \(step)%\n")
    }

    /// Ends the rewritten terminal line.
    func finish() {
        if !silent, Console.stderrIsTTY, last.withLock({ $0 }) >= 0 { Console.stderr("\n") }
    }
}
