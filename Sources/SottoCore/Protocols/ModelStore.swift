import Foundation

public struct ModelID: Sendable, Equatable, Hashable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

public enum ModelAvailability: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case failed(reason: String)      // download
    case loadFailed(reason: String)  // file present, but llama couldn't load it
}

public protocol ModelStore: Sendable {
    func availability(for model: ModelID) async -> ModelAvailability
    /// Concurrent callers share one download and its result (MS-05); `progress` is in [0, 1].
    func ensureDownloaded(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws
    func url(for model: ModelID) async -> URL?
    /// `force` re-fetches weights that are present but won't load (a corrupt cache). Stores that
    /// can't replace their copy treat it as a plain `ensureDownloaded`.
    func ensureDownloaded(_ model: ModelID, force: Bool, progress: @escaping @Sendable (Double) -> Void) async throws
}

extension ModelStore {
    public func ensureDownloaded(_ model: ModelID, force: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ensureDownloaded(model, progress: progress)
    }
}

/// Thrown when an engine is asked to load weights nobody fetched (ADR §5): only an explicit
/// `ModelStore.ensureDownloaded` touches the network, never `prewarm()` or `transcribe()`.
public struct ModelNotDownloaded: Error, Equatable, CustomStringConvertible {
    public let model: ModelID
    public init(_ model: ModelID) { self.model = model }
    public var description: String { "\(model.name) is not downloaded; call ModelStore.ensureDownloaded first" }
}
