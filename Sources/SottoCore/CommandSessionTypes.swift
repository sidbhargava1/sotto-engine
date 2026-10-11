// What a host sees and supplies when voice commands run through `DictationSession`. Plain data and
// closed enums: no event carries a transcript. Only `CommandFailure.notFound` and `.ambiguous`
// name the spoken target, because the capsule shows "Didn't find an app called Slak".
import Foundation

/// Which key started a press. The dictation key always dictates; only the command key is command mode.
enum TriggerKind: Sendable, Equatable {
    case dictation
    case command
}

/// Command progress for the host's indicator, separate from `SessionState` (which still carries the
/// recording / transcribing / error / idle lifecycle for both kinds of press).
///
/// A command run emits, in order: `listening` (command key only), `working` (command key only),
/// `recognisedAsCommand` (prefix path only), then exactly one of
/// - `acting(_)` then `finished(_)` for app, folder, link and hide commands;
/// - `running(shortcut:)` then `finished(_)` for a Shortcut (preceded by `confirmPending` when Ask first is on);
/// - `failed(_)`, `cancelled`.
public enum CommandPhase: Sendable, Equatable {
    /// The command key went down and capture started (never for a dictation press).
    case listening
    /// The command key was released (or the 15 s cap fired); speech-to-text and routing follow.
    case working
    /// The transcript resolved. Carries the action, never the transcript. Not sent for Shortcuts.
    case acting(ResolvedCommand)
    /// A Shortcut with Ask first is waiting for a tap on the command key. Carries its name.
    case confirmPending(shortcut: String)
    /// A Shortcut was confirmed (or needs no confirm) and is being started. Carries its name, since
    /// with Ask first off there was no `confirmPending` to learn it from.
    case running(shortcut: String)
    case finished(CommandOutcome)
    case failed(CommandFailure)
    /// A pending confirm timed out, was answered by a dictation-key press, or the session stopped.
    case cancelled
    /// Prefix path only: after the raw transcript was classified, a dictation press turned out to be
    /// a command. Never sent from partials.
    case recognisedAsCommand
}

/// Read once per press, so a mid-utterance Settings change applies from the next press.
public struct CommandInputs: Sendable, Equatable {
    /// The master switch. Off ignores the command key and the prefix.
    public var commandsEnabled: Bool
    /// False when the command shortcut is cleared: command-key presses are ignored.
    public var commandKeyEnabled: Bool
    /// "Also accept Sotto, ... on the dictation key".
    public var prefixEnabled: Bool
    /// False when no command key is bound. A Shortcut that needs a confirm on the prefix path then
    /// fails with `CommandFailure.confirmKeyUnavailable` instead of waiting for a tap that can't come.
    public var confirmKeyAvailable: Bool
    /// Stretches the confirm timeout from 8 s to 10 s.
    public var voiceOverRunning: Bool

    public init(
        commandsEnabled: Bool = false, commandKeyEnabled: Bool = true, prefixEnabled: Bool = false,
        confirmKeyAvailable: Bool = true, voiceOverRunning: Bool = false
    ) {
        self.commandsEnabled = commandsEnabled
        self.commandKeyEnabled = commandKeyEnabled
        self.prefixEnabled = prefixEnabled
        self.confirmKeyAvailable = confirmKeyAvailable
        self.voiceOverRunning = voiceOverRunning
    }

    public static let disabled = CommandInputs()

    var confirmTimeout: Duration { .seconds(voiceOverRunning ? 10 : 8) }
}

/// The confirm state machine for a Shortcut set to Ask first. Resolves exactly once: the first
/// transition out of `pending` wins and every later one is refused.
enum ConfirmState: Sendable, Equatable {
    case pending, confirmed, cancelled, timedOut
}
