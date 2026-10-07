// PLAN §3 consequence 1. `.whole` holds the stream until it ends and emits one chunk: one AX
// write instead of one per word (20-60ms each), which proved both slow and distracting in use (2026-10-01).
// `.streamed` keeps the word-boundary/~50ms batching. `.stalled` covers "no first token within
// 1.5s" and ">1s between tokens" (PLAN §4) in both modes.
import Foundation

public enum CoalescedEvent: Sendable, Equatable {
    case chunk(String)
    case stalled
}

public enum DeliveryMode: Sendable, Equatable {
    case whole
    case streamed
}

public struct CoalescerConfig: Sendable {
    public var delivery: DeliveryMode
    public var flushInterval: Duration
    public var firstTokenTimeout: Duration
    public var stallTimeout: Duration

    public init(delivery: DeliveryMode = .streamed, flushInterval: Duration = .milliseconds(50), firstTokenTimeout: Duration = .milliseconds(1500), stallTimeout: Duration = .seconds(1)) {
        self.delivery = delivery
        self.flushInterval = flushInterval
        self.firstTokenTimeout = firstTokenTimeout
        self.stallTimeout = stallTimeout
    }
}

public enum StreamCoalescer {
    public static func coalesce(_ source: AsyncThrowingStream<String, Error>, config: CoalescerConfig = .init()) -> AsyncThrowingStream<CoalescedEvent, Error> {
        AsyncThrowingStream { continuation in
            let state = CoalescerState(delivery: config.delivery)
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await token in source {
                                if let flushed = await state.appendAndMaybeFlush(token) {
                                    continuation.yield(.chunk(flushed))
                                }
                            }
                            if let remainder = await state.finish() {
                                continuation.yield(.chunk(remainder))
                            }
                            continuation.finish()
                        } catch {
                            if let remainder = await state.finish() {
                                continuation.yield(.chunk(remainder))
                            }
                            continuation.finish(throwing: error)
                        }
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(for: config.flushInterval)
                            } catch {
                                return
                            }
                            switch await state.tick(flushInterval: config.flushInterval, stallTimeout: config.stallTimeout, firstTokenTimeout: config.firstTokenTimeout) {
                            case .flush(let text):
                                continuation.yield(.chunk(text))
                            case .stalled:
                                continuation.yield(.stalled)
                                return
                            case .none:
                                break
                            }
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor CoalescerState {
    private let delivery: DeliveryMode
    private var pending = ""

    init(delivery: DeliveryMode) { self.delivery = delivery }
    private var receivedAnyToken = false
    private let startedAt = ContinuousClock.now
    private var lastTokenAt = ContinuousClock.now
    private var lastFlushAt = ContinuousClock.now

    enum TickResult: Equatable {
        case flush(String)
        case stalled
        case none
    }

    func appendAndMaybeFlush(_ token: String) -> String? {
        pending += token
        lastTokenAt = .now
        receivedAnyToken = true
        guard delivery == .streamed, let lastSpace = pending.lastIndex(of: " ") else { return nil }
        let boundaryEnd = pending.index(after: lastSpace)
        let flushed = String(pending[pending.startIndex..<boundaryEnd])
        pending = String(pending[boundaryEnd...])
        lastFlushAt = .now
        return flushed
    }

    func tick(flushInterval: Duration, stallTimeout: Duration, firstTokenTimeout: Duration) -> TickResult {
        let now = ContinuousClock.now
        if !receivedAnyToken {
            return now - startedAt >= firstTokenTimeout ? .stalled : .none
        }
        if now - lastTokenAt >= stallTimeout {
            return .stalled
        }
        if delivery == .streamed, !pending.isEmpty, now - lastFlushAt >= flushInterval {
            let flushed = pending
            pending = ""
            lastFlushAt = now
            return .flush(flushed)
        }
        return .none
    }

    func finish() -> String? {
        guard !pending.isEmpty else { return nil }
        let remainder = pending
        pending = ""
        return remainder
    }
}
