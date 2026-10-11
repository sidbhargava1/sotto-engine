// Parsed command + catalogue -> a resolved action or a typed failure. Kinds never cross: "open"
// never runs a Shortcut and "run" never opens an app. No guessing: two candidates is ambiguous.
import Foundation

public enum CommandAppState: Sendable, Equatable {
    case notRunning  // "Opening X"
    case running     // "Switching to X"
    case frontmost   // "Already in X"
}

/// What the host should do. For app commands the capsule copy is driven by `state`, not the case:
/// `.notRunning` is "Opening", `.running` is "Switching to", `.frontmost` is "Already in". The
/// case (`.open` vs `.switchTo`) records which verb was spoken, for per-verb counters. Both launch
/// a closed app and bring a running one forward.
public enum ResolvedCommand: Sendable, Equatable {
    case open(CatalogApp, state: CommandAppState)
    case switchTo(CatalogApp, state: CommandAppState)
    /// Only produced for a running app (frontmost counts as running).
    case hide(CatalogApp)
    case openFolder(CatalogItem)
    case openLink(CatalogItem)
    case runShortcut(CatalogShortcut)

    /// The spoken verb. Folders and links are "open"; shortcuts are "run".
    public var verb: CommandVerb {
        switch self {
        case .open, .openFolder, .openLink: return .open
        case .switchTo: return .switchTo
        case .hide: return .hide
        case .runShortcut: return .run
        }
    }
}

/// Carries heard text (`notFound`/`ambiguous`), as does `ParsedCommand`: never interpolate either
/// into a log. Log or count `kind`, which has no payload.
public enum CommandFailure: Error, Sendable, Equatable {
    /// Not a command, a deictic or over-long target, or no object. The host shows what was heard.
    case unrecognised
    /// `spoken` is the target as heard.
    case notFound(CommandTargetKind, spoken: String)
    case ambiguous(spoken: String, candidates: [String])
    case notRunning(CatalogApp)
    case shortcutsOff
    /// Prefix path only: the Shortcut needs a confirm tap, but no command key is bound. The host
    /// shows "Set a command shortcut to confirm".
    case confirmKeyUnavailable

    /// Payload-free and closed: safe for logs and counters.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case unrecognised, notFound, ambiguous, notRunning, shortcutsOff, confirmKeyUnavailable
    }

    public var kind: Kind {
        switch self {
        case .unrecognised: return .unrecognised
        case .notFound: return .notFound
        case .ambiguous: return .ambiguous
        case .notRunning: return .notRunning
        case .shortcutsOff: return .shortcutsOff
        case .confirmKeyUnavailable: return .confirmKeyUnavailable
        }
    }
}

public enum CommandResolver {
    public static func resolve(_ command: ParsedCommand, in catalog: CommandCatalog) -> Result<ResolvedCommand, CommandFailure> {
        let spoken = command.target
        switch command.verb {
        case .open:
            switch command.forcedKind {
            case .folder?: return named(catalog.folders, .folder, spoken).map(ResolvedCommand.openFolder)
            case .link?: return named(catalog.links, .link, spoken).map(ResolvedCommand.openLink)
            default: break
            }
            // A named item beats an app of the same name.
            let folders = catalog.folders.filter { key($0.spokenName) == key(spoken) }
            let links = catalog.links.filter { key($0.spokenName) == key(spoken) }
            switch (folders.count, links.count) {
            case (1, 0): return .success(.openFolder(folders[0]))
            case (0, 1): return .success(.openLink(links[0]))
            case (0, 0): return app(command, spoken, catalog)
            default:
                return .failure(.ambiguous(spoken: spoken, candidates: (folders + links).map(\.spokenName)))
            }
        case .switchTo, .hide:
            return app(command, spoken, catalog)
        case .run:
            guard catalog.shortcutsEnabled else { return .failure(.shortcutsOff) }
            switch find(spoken, in: catalog.shortcuts.map { ($0.name, $0) }) {
            case .one(let s): return .success(.runShortcut(s))
            case .many(let all): return .failure(.ambiguous(spoken: spoken, candidates: all.map(\.name)))
            case .none: return .failure(.notFound(.shortcut, spoken: spoken))
            }
        }
    }

    private static func named(_ items: [CatalogItem], _ kind: CommandTargetKind, _ spoken: String)
        -> Result<CatalogItem, CommandFailure> {
        let hits = items.filter { key($0.spokenName) == key(spoken) }
        switch hits.count {
        case 0: return .failure(.notFound(kind, spoken: spoken))
        case 1: return .success(hits[0])
        default: return .failure(.ambiguous(spoken: spoken, candidates: hits.map(\.spokenName)))
        }
    }

    private static func app(_ command: ParsedCommand, _ spoken: String, _ catalog: CommandCatalog)
        -> Result<ResolvedCommand, CommandFailure> {
        // Dedupe the matches by id, not the inputs: a second name for the same bundle ID can still match.
        var found = find(spoken, in: catalog.apps.map { ($0.name, $0) })
        if case .many(let all) = found {
            var seen = Set<String>()
            let unique = all.filter { seen.insert($0.id).inserted }
            found = unique.count == 1 ? .one(unique[0]) : .many(unique)
        }
        switch found {
        case .none: return .failure(.notFound(.app, spoken: spoken))
        case .many(let all): return .failure(.ambiguous(spoken: spoken, candidates: all.map(\.name)))
        case .one(let app):
            let running = catalog.runningAppIDs.contains(app.id) || catalog.frontmostAppID == app.id
            if command.verb == .hide {
                return running ? .success(.hide(app)) : .failure(.notRunning(app))
            }
            let state: CommandAppState = catalog.frontmostAppID == app.id ? .frontmost
                : running ? .running : .notRunning
            return .success(command.verb == .switchTo ? .switchTo(app, state: state) : .open(app, state: state))
        }
    }

    enum Found<T> { case none, one(T), many([T]) }

    /// Exact normalised name wins; else a contiguous whole-word part of exactly one name.
    static func find<T>(_ spoken: String, in items: [(name: String, value: T)]) -> Found<T> {
        let spokenKey = key(spoken)
        guard !spokenKey.isEmpty else { return .none }
        let exact = items.filter { key($0.name) == spokenKey }.map(\.value)
        if !exact.isEmpty { return exact.count == 1 ? .one(exact[0]) : .many(exact) }

        let spokenWords = nameWords(spoken)
        let partial = items.filter { contains(nameWords($0.name), spokenWords) }.map(\.value)
        switch partial.count {
        case 0: return .none
        case 1: return .one(partial[0])
        default: return .many(partial)
        }
    }

    /// Case and diacritics folded (so NFC and NFD agree), then letters and digits only: "x code",
    /// "X-Code" and "Xcode" compare equal, and so do "Café" and "cafe".
    static func key(_ s: String) -> String {
        String(String.UnicodeScalarView(fold(s).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func nameWords(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !$0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) })
            .map(String.init)
    }

    private static func contains(_ name: [String], _ part: [String]) -> Bool {
        guard !part.isEmpty, part.count <= name.count else { return false }
        return (0...(name.count - part.count)).contains { Array(name[$0..<($0 + part.count)]) == part }
    }
}
