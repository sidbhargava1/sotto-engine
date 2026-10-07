// Bundle ID needs no permission; the focused element needs Accessibility and is an identity
// token for the guarded "scratch that" check (PLAN §4) plus the history secure-field probe.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SottoCore
import os

public struct WorkspaceContextProvider: TargetContextProviding {
    private let log: Logger
    private let axLog: Logger
    private let terminalBundleIDs: Set<String>

    public init(log: LogSubsystem, terminalBundleIDs: Set<String> = DefaultInjectionPolicy.terminalBundleIDs) {
        self.log = log.logger("context")
        axLog = log.logger("ax")
        self.terminalBundleIDs = terminalBundleIDs
    }

    public func currentContext(probeSecure: Bool) async -> TargetContext {
        let (bundleID, pid) = await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.bundleIdentifier, app?.processIdentifier)
        }
        let trusted = AXIsProcessTrusted()
        let element = trusted ? await AccessibilityFocus.focusedElementOnOwner(appPID: pid, log: axLog) : nil
        // The focus owner for the press/release moved check. AXUIElementGetPid reads the ref
        // locally (no AX message), so release costs nothing extra. Untrusted mirrors the press
        // probe's frontmost fallback; trusted without an element stays nil, and resolveTarget
        // then compares frontmost for the moved check.
        var ownerPID: pid_t = 0
        let focusOwner: String? = if let element, AXUIElementGetPid(element, &ownerPID) == .success {
            NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
        } else {
            trusted ? nil : bundleID
        }
        var secure = true  // unprobed counts as secure; History is off so nothing records anyway
        if probeSecure {
            let probeStart = ContinuousClock.now
            secure = await AccessibilityFocus.onOwner(of: element) { AccessibilityFocus.isSecureInput($0, trusted: trusted, timeout: 0.25) }
            log.info("secure probe: secure=\(secure, privacy: .public) probeMs=\(Self.ms(since: probeStart), privacy: .public)")
        }
        let editable = await AccessibilityFocus.onOwner(of: element) { $0.map(AccessibilityFocus.isEditable) ?? false }
        return TargetContext(
            bundleID: bundleID,
            isTerminalClass: bundleID.map(terminalBundleIDs.contains) ?? false,
            // Only an editable element counts (DS-06b): a focused button or list would otherwise
            // send a paste nowhere and restore the clipboard, losing the text (observed in use).
            elementToken: element.flatMap { editable ? AXElementToken(CFHash($0)) : nil },
            accessibilityGranted: trusted,
            isSecureInput: secure,
            elementHandle: element.map { AXElementHandle($0) },
            focusOwnerBundleID: focusOwner
        )
    }

    // Runs under the session's injectionLock, so: no focus re-fetch and a 50ms AX timeout.
    public func isSecureNow(_ context: TargetContext) async -> Bool {
        let start = ContinuousClock.now
        let element = context.elementHandle.map { unsafeDowncast($0.element, to: AXUIElement.self) }
        let trusted = AXIsProcessTrusted()
        let secure = await AccessibilityFocus.onOwner(of: element) { AccessibilityFocus.isSecureInput($0, trusted: trusted, timeout: 0.05) }
        log.info("secure recheck: secure=\(secure, privacy: .public) probeMs=\(Self.ms(since: start), privacy: .public)")
        return secure
    }

    /// The keyboard-focus owner at hotkey-down, off the press path (the session doesn't await it):
    /// the injection target's identity (terminal or not) and the History row's app.
    /// AX focused app first: a non-activating panel such as iTerm2's floating hotkey window takes
    /// keys without becoming NSWorkspace's frontmost, which then still names Sotto or whatever was
    /// active before. Sotto itself is nil, whatever its bundle ID.
    public func pressTimeApp() async -> String? {
        let axPID = AXIsProcessTrusted() ? AccessibilityFocus.focusedAppPID() : nil
        let app = await MainActor.run { () -> (bundleID: String?, viaAX: Bool, differs: Bool)? in
            let frontmost = NSWorkspace.shared.frontmostApplication
            let owner = axPID.flatMap(NSRunningApplication.init(processIdentifier:)) ?? frontmost
            guard let owner, owner.processIdentifier != getpid() else { return nil }
            return (owner.bundleIdentifier, owner.processIdentifier == axPID, owner.processIdentifier != frontmost?.processIdentifier)
        }
        log.info("press app: via=\(app.map { $0.viaAX ? "ax" : "workspace" } ?? "self-or-none", privacy: .public) differsFromFrontmost=\(app?.differs ?? false, privacy: .public)")
        return app?.bundleID
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        String(format: "%.2f", (ContinuousClock.now - start) / .microseconds(1) / 1000)
    }
}

public enum AccessibilityFocus {
    // Own-process hazard (0.2.1 crash): AX calls on one of Sotto's own elements don't go over IPC;
    // HIServices runs AppKit's accessibility code in-process on the calling thread, and AppKit
    // asserts the main queue (setSelectedText → NSTextView → TSM). Other apps' elements are
    // blocking IPC, so those calls stay off main and never stall the UI.

    static func isOwn(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == getpid()  // reads the ref; no AX message
    }

    /// Runs `body` on the main actor when `element` is Sotto's own, else on the caller's thread.
    public static func onOwner<T: Sendable>(of element: AXUIElement?, _ body: @Sendable (AXUIElement?) -> T) async -> T {
        guard let element, isOwn(element) else { return body(element) }
        let handle = AXElementHandle(element)
        return await MainActor.run { body(unsafeDowncast(handle.element, to: AXUIElement.self)) }
    }

    /// `focusedElement`, read on main when Sotto itself is frontmost: the system-wide query is
    /// then answered by our own AppKit in-process.
    static func focusedElementOnOwner(appPID: pid_t?, log: Logger? = nil) async -> AXUIElement? {
        guard appPID == getpid() else { return focusedElement(appPID: appPID, log: log) }
        let handle = await MainActor.run { focusedElement(appPID: appPID, log: log).map(AXElementHandle.init) }
        return handle.map { unsafeDowncast($0.element, to: AXUIElement.self) }
    }

    // System-wide first; then the app element, after nudging Chromium/Electron to enable
    // accessibility (they expose nothing until an assistive client asks). AXManualAccessibility
    // only, once per process: AXEnhancedUserInterface is sticky and slows Chrome/Electron windows.
    nonisolated(unsafe) private static var nudgedPIDs = Set<pid_t>()
    public static func focusedElement(appPID: pid_t? = nil, log: Logger? = nil) -> AXUIElement? {
        if let element = focusedElementSystemWide(log: log) { return element }
        guard let appPID else { return nil }
        let app = AXUIElementCreateApplication(appPID)
        if appPID != getpid(), !nudgedPIDs.contains(appPID) {  // Chromium nudge; never needed for us
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            nudgedPIDs.insert(appPID)
        }
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref)
        guard err == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            log?.debug("no focused element via app (\(err.rawValue))")
            return nil
        }
        return (ref as! AXUIElement)
    }

    // No AXWebArea: a browser page with nothing focused reports the page itself, and that
    // would re-create the lost-paste bug. Editable web content answers the settable check.
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func isEditable(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success, let role = ref as? String else { return false }
        return editableRoles.contains(role)
    }

    /// SPEC §15.1 (a)/(b). Anything we can't see counts as secure: no AX trust, or a subrole
    /// read that errors or times out (rulings QA 9, HI-25). No focused element is not a failure.
    static func isSecureInput(_ element: AXUIElement?, trusted: Bool, timeout: Float) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard trusted else { return true }
        guard let element else { return false }
        AXUIElementSetMessagingTimeout(element, timeout)
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref) {
        case .success: return (ref as? String) == kAXSecureTextFieldSubrole
        case .noValue, .attributeUnsupported: return false
        default: return true
        }
    }

    /// Bounded like the secure probe, else a hung focused app holds this for the ~6s default (the
    /// session also bounds its wait). On the system-wide element the timeout is process-global, so
    /// it matches the indicator's key-down probe (0.1s) rather than racing it to a different value.
    static func focusedAppPID(timeout: Float = 0.1) -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(ref as! AXUIElement, &pid) == .success ? pid : nil
    }

    static func focusedElementSystemWide(log: Logger? = nil) -> AXUIElement? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &ref)
        guard err == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            log?.debug("no focused element (\(err.rawValue))")
            return nil
        }
        return (ref as! AXUIElement)
    }
}
