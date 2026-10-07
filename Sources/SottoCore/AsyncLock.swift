// FIFO mutex for utterance-level injection ordering (DS-02). A plain actor call isn't enough —
// Swift actors are reentrant across await points, so two concurrent injection sequences could
// still interleave without an explicit queue like this one.
import Foundation

actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
    }

    func runExclusive<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try await work()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}
