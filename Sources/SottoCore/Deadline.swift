// Bounds a wait on a task that can't be cancelled (a blocking AX call doesn't check for it).
import Foundation

public enum Deadline {
    public typealias Sleeper = @Sendable (Duration) async -> Void
    public static let realSleep: Sleeper = { try? await Task.sleep(for: $0) }

    /// The task's value if it finishes within `limit`, else nil. Unstructured on purpose: a task
    /// group would wait for the losing child, which is the hang this exists to avoid.
    public static func value<T: Sendable>(of task: Task<T, Never>, within limit: Duration, sleep: @escaping Sleeper = realSleep) async -> T? {
        let once = Once<T?>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            let timer = Task { await sleep(limit); once.resume(nil) }
            Task { once.resume(await task.value); timer.cancel() }
        }
    }
}

/// First resume wins; later ones are dropped.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func set(_ continuation: CheckedContinuation<T, Never>) { lock.withLock { self.continuation = continuation } }

    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
