import Foundation

/// `DictationSession` only ever sees discrete edges, never physical modifier state (DS-08), and
/// doesn't know which key fired — a rebind applies to the adapter, not here (DS-10).
public protocol HotkeyMonitoring: Sendable {
    func events() -> AsyncStream<HotkeyEvent>
}
