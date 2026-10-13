// What the host knows about the machine, handed to the resolver as plain data. The engine never
// interprets the opaque identifiers and targets: the host decides what they mean.
import Foundation

public enum CommandTargetKind: Sendable, Equatable {
    case app, folder, link, shortcut
}

/// An installed app. `id` is opaque to the engine (the host passes a bundle ID).
public struct CatalogApp: Sendable, Equatable, Hashable {
    public let name: String
    public let id: String
    public init(name: String, id: String) {
        self.name = name
        self.id = id
    }
}

/// A user-named folder or link. `target` is opaque to the engine (the host passes a path or URL string).
public struct CatalogItem: Sendable, Equatable, Hashable {
    public let spokenName: String
    public let target: String
    public init(spokenName: String, target: String) {
        self.spokenName = spokenName
        self.target = target
    }
}

/// A Shortcut in the allowed folder. Ask-first defaults to on, like a renamed Shortcut.
public struct CatalogShortcut: Sendable, Equatable, Hashable {
    public let name: String
    public let askFirst: Bool
    public init(name: String, askFirst: Bool = true) {
        self.name = name
        self.askFirst = askFirst
    }
}

public struct CommandCatalog: Sendable, Equatable {
    public var apps: [CatalogApp]
    /// IDs of running apps (a subset of `apps` IDs).
    public var runningAppIDs: Set<String>
    public var frontmostAppID: String?
    public var folders: [CatalogItem]
    public var links: [CatalogItem]
    /// Only the Shortcuts in the allowed folder; "run X" never looks anywhere else.
    public var shortcuts: [CatalogShortcut]
    public var shortcutsEnabled: Bool
    /// The allowed folder's name, for hosts that show it; the resolver doesn't read it.
    public var shortcutsFolderName: String

    public init(
        apps: [CatalogApp] = [], runningAppIDs: Set<String> = [], frontmostAppID: String? = nil,
        folders: [CatalogItem] = [], links: [CatalogItem] = [],
        shortcuts: [CatalogShortcut] = [], shortcutsEnabled: Bool = false, shortcutsFolderName: String = ""
    ) {
        self.apps = apps
        self.runningAppIDs = runningAppIDs
        self.frontmostAppID = frontmostAppID
        self.folders = folders
        self.links = links
        self.shortcuts = shortcuts
        self.shortcutsEnabled = shortcutsEnabled
        self.shortcutsFolderName = shortcutsFolderName
    }
}
