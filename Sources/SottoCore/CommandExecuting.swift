// The seam between the engine and the host's system calls (NSWorkspace, the shortcuts tool). The
// engine never imports AppKit; the host conforms. An executor must not type, press keys or touch
// the pasteboard.
import Foundation

public enum CommandOutcome: Sendable, Equatable {
    case done
    /// Hide raced with the app quitting.
    case notRunning
    /// Open or switch for an app, folder or link failed.
    case launchFailed
    case hideFailed
    /// The Shortcut exited non-zero.
    case shortcutFailed
    /// The host's label cap passed while the Shortcut kept running.
    case shortcutStillRunning
}

public protocol CommandExecuting: Sendable {
    func execute(_ command: ResolvedCommand) async -> CommandOutcome
}
