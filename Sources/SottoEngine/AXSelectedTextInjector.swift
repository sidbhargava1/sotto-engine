// kAXSelectedTextAttribute only — kAXValue would replace the whole field (CLAUDE.md).
import AppKit
import ApplicationServices
import SottoCore
import os

public struct AXSelectedTextInjector: TextInjecting {
    private let log: Logger

    public init(log: LogSubsystem) { self.log = log.logger("inject") }

    public func append(_ text: String, to context: TargetContext) async -> InjectionOutcome {
        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard AXIsProcessTrusted(), let element = await AccessibilityFocus.focusedElementOnOwner(appPID: pid, log: log) else { return .failed }
        // Our own window (onboarding's Try it): the write and its read-backs must run on main
        // (AccessibilityFocus "own-process hazard"); anything else stays on this thread.
        let before = await AccessibilityFocus.onOwner(of: element) { $0.flatMap(Self.characterCount) }
        let err = await AccessibilityFocus.onOwner(of: element) {
            AXUIElementSetAttributeValue($0!, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        }
        guard err == .success else {
            log.info("AX write failed (\(err.rawValue)) in \(context.bundleID ?? "?", privacy: .public)")
            return .failed
        }
        // Success from Chromium/Electron shims proves nothing, and an unreadable count or a
        // selection replacement isn't failure either — .unverified never falls back (DS-05).
        guard let before else { return .unverified }
        // Chromium/Electron apply AX writes asynchronously; poll before calling it a miss.
        var after = await AccessibilityFocus.onOwner(of: element) { $0.flatMap(Self.characterCount) }
        for _ in 0..<5 where after == before {
            try? await Task.sleep(for: .milliseconds(20))
            after = await AccessibilityFocus.onOwner(of: element) { $0.flatMap(Self.characterCount) }
        }
        guard let after else { return .unverified }
        if after == before { return .failed } // nothing landed: let paste try
        return after - before == text.utf16.count ? .success : .unverified
    }

    /// AX character counts are UTF-16 units.
    static func characterCount(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success
        else { return nil }
        return (ref as? NSNumber)?.intValue
    }
}
