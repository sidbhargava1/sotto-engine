import Foundation

/// Bounds engine restarts driven by AVAudioEngineConfigurationChange (SPEC §5 "Restart budget").
/// A flapping Bluetooth HFP route reconfigures again each time the restart reopens the mic; past
/// the budget the adapter gives up on that device and falls back (InputSelection.markUnstable).
/// A healthy route switch costs one or two restarts, so the normal path never sees it.
public struct RestartBudget: Sendable, Equatable {
    /// More than `limit` restarts on one device within `window` gives up on it.
    public static let limit = 4
    public static let window: Duration = .seconds(10)
    /// A change this soon after a restart finished is that restart's own echo: one trailing
    /// restart covers it, never one per notification.
    public static let coalesce: Duration = .milliseconds(100)

    public enum Decision: Sendable, Equatable {
        case restart
        /// Check again after this long (one trailing restart, if the engine still needs it).
        case coalesce(after: Duration)
        case giveUp
    }

    private let limit: Int
    private let window: Duration
    private let coalesceWindow: Duration
    private var device: String?
    private var restarts: [ContinuousClock.Instant] = []
    private var lastFinished: ContinuousClock.Instant?

    public init(limit: Int = limit, window: Duration = window, coalesce: Duration = coalesce) {
        self.limit = limit
        self.window = window
        self.coalesceWindow = coalesce
    }

    /// A configuration change arrived while the engine is on `device`. nil (unknown, e.g. the
    /// last restart failed) keeps counting against the current device: a storm that alternates
    /// failed and successful restarts must still trip the budget.
    public mutating func configurationChanged(device: String?, at now: ContinuousClock.Instant) -> Decision {
        if let device, device != self.device { reset(); self.device = device }
        if let lastFinished, now - lastFinished < coalesceWindow {
            return .coalesce(after: coalesceWindow - (now - lastFinished))
        }
        let window = self.window
        restarts.removeAll { now - $0 >= window }
        guard restarts.count < limit else {
            reset()
            return .giveUp
        }
        restarts.append(now)
        return .restart
    }

    /// The restart (successful or not) finished at `now`; anchors the coalescing window.
    public mutating func restartFinished(at now: ContinuousClock.Instant) {
        lastFinished = now
    }

    /// Device list or picker changed, or a dictation captured real audio.
    public mutating func reset() {
        restarts = []
        lastFinished = nil
    }

    /// Restarts counted in the current window, for the log.
    public var count: Int { restarts.count }
}
