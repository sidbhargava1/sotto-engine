import Foundation

/// The Settings mic picker's choice against what's plugged in and what actually started
/// (ui-spec §4). nil device = the system default. The stored choice is never overwritten: a
/// missing or failing device falls back for now and is tried again on the next start.
public struct InputSelection: Sendable, Equatable {
    public private(set) var preferred: String?
    private var chosenFailed = false  // the chosen device failed to start; cleared by a start on it
    /// Devices that kept reconfiguring (RestartBudget). Skipped until the picker changes or the
    /// device disconnects; a relaunch also forgets them.
    public private(set) var unstable: Set<String> = []

    public init(preferred: String? = nil) {
        self.preferred = preferred
    }

    public mutating func choose(_ uid: String?) {
        preferred = uid
        chosenFailed = false
        unstable = []
    }

    /// Devices to try, in order, on each engine start. With nothing unstable the extra arguments
    /// change nothing. An entry resolving to an unstable device (nil resolves to `defaultUID`)
    /// is replaced by the first stable, available `fallbacks` entry, or dropped: an empty list
    /// means nothing stable is left to open.
    public func attempts(available: [String], defaultUID: String? = nil, fallbacks: [String] = []) -> [String?] {
        let base: [String?] = if let preferred, available.contains(preferred) { [preferred, nil] } else { [nil] }
        guard !unstable.isEmpty else { return base }
        let fallback = fallbacks.first { available.contains($0) && !unstable.contains($0) }
        var out: [String?] = []
        for entry in base {
            let resolved = entry ?? defaultUID
            let pick: String?? = if let resolved, unstable.contains(resolved) { fallback.map { .some($0) } } else { .some(entry) }
            if let pick, !out.contains(pick) { out.append(pick) }
        }
        return out
    }

    /// The device recording now, or the one the next start is expected to land on.
    public func expected(available: [String], defaultUID: String? = nil, fallbacks: [String] = []) -> String? {
        let list = attempts(available: available, defaultUID: defaultUID, fallbacks: fallbacks)
        if chosenFailed, let preferred, list.first == preferred { return list.dropFirst().first ?? nil }
        return list.first ?? nil
    }

    /// Settings footnote: a device is chosen but the system default stands in, or an unstable
    /// device has been swapped out.
    public func fellBack(available: [String], defaultUID: String? = nil, fallbacks: [String] = []) -> Bool {
        if unstableStandIn(available: available, defaultUID: defaultUID, fallbacks: fallbacks) != nil { return true }
        return preferred != nil && expected(available: available, defaultUID: defaultUID, fallbacks: fallbacks) == nil
    }

    /// The unstable device the next start would have opened but won't, if any.
    public func unstableStandIn(available: [String], defaultUID: String? = nil, fallbacks: [String] = []) -> String? {
        guard !unstable.isEmpty else { return nil }
        let base = attempts(available: available)  // what it would be with nothing unstable
        let wanted = chosenFailed ? base.dropFirst().first ?? nil : base.first ?? nil
        guard let resolved = wanted ?? defaultUID, unstable.contains(resolved) else { return nil }
        return resolved
    }

    public mutating func started(on uid: String?) {
        if uid != nil, uid == preferred { chosenFailed = false }
    }

    public mutating func failed(on uid: String?) {
        if uid != nil, uid == preferred { chosenFailed = true }
    }

    /// The device kept reconfiguring past the RestartBudget: skip it from the next start.
    public mutating func markUnstable(_ uid: String) {
        unstable.insert(uid)
    }

    /// Forgets unstable devices that have disconnected, so a reconnect gets a fresh chance.
    public mutating func devicesChanged(available: [String]) {
        unstable.formIntersection(available)
    }
}
