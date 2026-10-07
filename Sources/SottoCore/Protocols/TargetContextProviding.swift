import Foundation

public protocol TargetContextProviding: Sendable {
    /// `probeSecure` false skips the secure-field probe (the recorder wants nothing, so nothing can record);
    /// the context then reports `isSecureInput` true so it can never pass the gate by accident.
    func currentContext(probeSecure: Bool) async -> TargetContext
    /// Post-landing re-check (HI-24) of the element `context` captured, without re-fetching
    /// focus. True when secure or unknown (fail closed).
    func isSecureNow(_ context: TargetContext) async -> Bool
    /// The app that owns keyboard focus at hotkey-down (nil: unknown, or Sotto itself): the
    /// injection target's identity and the record's app. Read at press because by release
    /// Sotto's own windows or a non-activating panel can be "frontmost".
    func pressTimeApp() async -> String?
}
