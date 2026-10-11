// The two entry points a session calls. Both expect a transcript that has ALREADY been through
// `DictionaryRewriter.rewrite` (heard-as variants are the only alias source), and neither touches
// the system: the host gets a verdict and decides what to show and execute.
import Foundation

public enum CommandKeyResult: Sendable, Equatable {
    case resolved(ResolvedCommand)
    /// Nothing is typed on the command key, whatever the failure.
    case failed(CommandFailure)
}

public enum DictationKeyRouting: Sendable, Equatable {
    /// Exact "scratch that", handled by `CommandParser` as before.
    case scratchThat
    case command(ResolvedCommand)
    /// "Sotto, open Slak": show the failure and type nothing.
    case commandError(CommandFailure)
    /// Type the transcript unchanged, wake word included.
    case dictation
}

public enum CommandRouter {
    public static func routeCommandKey(_ transcript: String, catalog: CommandCatalog) -> CommandKeyResult {
        guard let parsed = CommandGrammar.parseCommandKey(transcript) else { return .failed(.unrecognised) }
        switch CommandResolver.resolve(parsed, in: catalog) {
        case .success(let resolved): return .resolved(resolved)
        case .failure(let failure): return .failed(failure)
        }
    }

    /// Order: exact "scratch that", then the command grammar, then dictation.
    public static func routeDictationKey(
        _ transcript: String, catalog: CommandCatalog, prefixEnabled: Bool
    ) -> DictationKeyRouting {
        if CommandParser.parse(transcript) == .scratchThat { return .scratchThat }
        guard prefixEnabled, case .command(let parsed) = CommandGrammar.scanPrefix(transcript) else {
            return .dictation
        }
        switch CommandResolver.resolve(parsed, in: catalog) {
        case .success(let resolved): return .command(resolved)
        // A longer target is more likely prose that starts with a verb ("Sotto open source release notes...").
        case .failure(let failure): return parsed.targetWordCount <= 2 ? .commandError(failure) : .dictation
        }
    }
}
