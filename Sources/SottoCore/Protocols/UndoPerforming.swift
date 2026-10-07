import Foundation

/// Fires the synthetic ⌘Z for "scratch that" (SPEC §9). The 30s/same-element guard lives in
/// `DictationSession`, not the adapter — this just performs the keystroke when told to.
public protocol UndoPerforming: Sendable {
    func undo(_ context: TargetContext) async -> Bool
}
