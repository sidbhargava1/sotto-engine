// Parsed command + catalogue -> a resolved action or a typed failure. Kinds never cross: "open"
// never runs a Shortcut and "run" never opens an app. No guessing: two candidates is ambiguous.
import Foundation

public enum CommandAppState: Sendable, Equatable {
    case notRunning  // "Opening X"
    case running     // "Switching to X"
    case frontmost   // "Already in X"
}

public enum ResolvedCommand: Sendable, Equatable {
    /// `verb` is `.open` or `.switchTo`; both launch a closed app and bring a running one forward.
    case app(CatalogApp, state: CommandAppState, verb: CommandVerb)
    /// Only produced for a running app.
    case hide(CatalogApp)
    case openFolder(CatalogItem)
    case openLink(CatalogItem)
    case runShortcut(name: String, askFirst: Bool)
}

public enum CommandFailure: Error, Sendable, Equatable {
    /// Not a command, a deictic or over-long target, or no object. The host shows what was heard.
    case unrecognised
    /// `spoken` is the target as heard.
    case notFound(CommandTargetKind, spoken: String)
    case ambiguous(spoken: String, candidates: [String])
    case notRunning(CatalogApp)
    case shortcutsOff
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
            case .one(let s): return .success(.runShortcut(name: s.name, askFirst: s.askFirst))
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
        var seen = Set<String>()
        let apps = catalog.apps.filter { seen.insert($0.id).inserted }
        switch find(spoken, in: apps.map { ($0.name, $0) }) {
        case .none: return .failure(.notFound(.app, spoken: spoken))
        case .many(let all): return .failure(.ambiguous(spoken: spoken, candidates: all.map(\.name)))
        case .one(let app):
            let running = catalog.runningAppIDs.contains(app.id) || catalog.frontmostAppID == app.id
            if command.verb == .hide {
                return running ? .success(.hide(app)) : .failure(.notRunning(app))
            }
            let state: CommandAppState = catalog.frontmostAppID == app.id ? .frontmost
                : running ? .running : .notRunning
            return .success(.app(app, state: state, verb: command.verb))
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

    /// Letters and digits only, lowercased: "x code", "X-Code" and "Xcode" all compare equal.
    static func key(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func nameWords(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) })
            .map(String.init)
    }

    private static func contains(_ name: [String], _ part: [String]) -> Bool {
        guard !part.isEmpty, part.count <= name.count else { return false }
        return (0...(name.count - part.count)).contains { Array(name[$0..<($0 + part.count)]) == part }
    }
}
