// The session's cleanup slot for the local model. Until weights and prefix are loaded (or while
// the GGUF is missing) it answers `.notReady`, which the session turns into raw text at once
// (LB-11, WR-03) instead of blocking the hotkey on a multi-second load.
import Foundation
import SottoCore
import Synchronization

public final class LocalCleanupBackend: CleanupBackend {
    private let current = Mutex<ModelCleanupBackend?>(nil)

    public init() {}

    public var model: ModelCleanupBackend? { current.withLock { $0 } }

    public func install(_ backend: ModelCleanupBackend?) { current.withLock { $0 = backend } }

    public func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
        guard let backend = model else {
            return AsyncThrowingStream { $0.finish(throwing: CleanupError.notReady) }
        }
        return backend.clean(request)
    }
}
