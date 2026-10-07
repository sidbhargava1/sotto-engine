import Foundation

public enum STTEngine: String, Sendable, Codable, CaseIterable {
    case parakeet
    case appleSpeechAnalyzer
}

public enum CleanupEngine: String, Sendable, Codable, CaseIterable {
    case local
    case raw
}

/// The engine's settings. A host keeps its own (Sotto: History, Appearance) in `extensions`, which
/// the engine carries in the press-time snapshot but never reads (open-core ADR §1).
public struct Settings: Sendable, Equatable {
    /// WR-02: the model is only asked when the local engine is chosen (`.raw` is cleanup off).
    public var usesModelCleanup: Bool { cleanupEngine == .local }

    public var sttEngine: STTEngine
    public var cleanupEngine: CleanupEngine
    public var paused: Bool
    public var fnKeyEnabled: Bool
    public var injectionOverrides: [String: InjectionStrategy]
    /// CoreAudio UID of the chosen mic; nil follows the macOS default (ui-spec §4).
    public var inputDeviceUID: String?
    public var extensions = SettingsExtensions()

    public init(
        sttEngine: STTEngine = .parakeet,
        cleanupEngine: CleanupEngine = .local,
        paused: Bool = false,
        fnKeyEnabled: Bool = false,
        injectionOverrides: [String: InjectionStrategy] = [:],
        inputDeviceUID: String? = nil
    ) {
        self.sttEngine = sttEngine
        self.cleanupEngine = cleanupEngine
        self.paused = paused
        self.fnKeyEnabled = fnKeyEnabled
        self.injectionOverrides = injectionOverrides
        self.inputDeviceUID = inputDeviceUID
    }
}

/// A host-defined setting stored in `Settings.extensions`, keyed by type like SwiftUI's
/// EnvironmentKey. The host exposes it as a computed property in an extension of `Settings`.
public protocol SettingsKey {
    associatedtype Value: Sendable & Equatable
    static var defaultValue: Value { get }
}

public struct SettingsExtensions: Sendable, Equatable {
    private struct Box: Sendable {
        let value: any Sendable
        let equals: @Sendable (any Sendable) -> Bool
    }

    // Only non-default values are stored, so "never set" and "set to the default" compare equal.
    private var values: [ObjectIdentifier: Box] = [:]

    public init() {}

    public subscript<Key: SettingsKey>(_ key: Key.Type) -> Key.Value {
        get { values[ObjectIdentifier(key)]?.value as? Key.Value ?? Key.defaultValue }
        set {
            values[ObjectIdentifier(key)] = newValue == Key.defaultValue
                ? nil
                : Box(value: newValue, equals: { ($0 as? Key.Value) == newValue })
        }
    }

    public static func == (lhs: SettingsExtensions, rhs: SettingsExtensions) -> Bool {
        lhs.values.count == rhs.values.count
            && lhs.values.allSatisfy { key, box in rhs.values[key].map { box.equals($0.value) } ?? false }
    }
}

public protocol SettingsStore: Sendable {
    func load() async -> Settings
    func save(_ settings: Settings) async
}
