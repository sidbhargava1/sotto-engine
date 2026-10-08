// The Accessibility side of replace-last (`FieldAccessing`). Reads and selection only, plus
// kAXSelectedText for the one write: never kAXValue, which replaces the whole field (CLAUDE.md).
import ApplicationServices
import SottoCore

public struct AXFieldAccess: FieldAccessing {
    private static let timeout: Float = 0.25  // a hung app must not stall the injection lock for long
    // The caret read sits on the release-to-landed path: like `isSecureNow`, 50ms. A miss only
    // means that landing isn't replaceable later.
    private static let caretTimeout: Float = 0.05

    public init() {}

    public func selectedRange(_ context: TargetContext) async -> FieldRange? {
        await run(context, timeout: Self.caretTimeout) { element in
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == AXValueGetTypeID()
            else { return nil }
            return Self.range(from: ref as! AXValue)
        } ?? nil
    }

    public func characterCount(_ context: TargetContext) async -> Int? {
        await run(context) { AXSelectedTextInjector.characterCount($0) } ?? nil
    }

    public func text(in range: FieldRange, _ context: TargetContext) async -> String? {
        await run(context) { element in
            guard let param = Self.axValue(range) else { return nil }
            var ref: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &ref) == .success
            else { return nil }
            return ref as? String
        } ?? nil
    }

    public func valueSubstring(in range: FieldRange, _ context: TargetContext) async -> String? {
        await run(context) { element in
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success, let value = ref as? String else { return nil }
            let units = Array(value.utf16)
            guard range.location >= 0, range.length >= 0, range.location + range.length <= units.count else { return nil }
            return String(utf16CodeUnits: Array(units[range.location..<range.location + range.length]), count: range.length)
        } ?? nil
    }

    public func setSelectedRange(_ range: FieldRange, _ context: TargetContext) async -> Bool {
        await run(context) { element in
            guard let value = Self.axValue(range) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
        } ?? false
    }

    public func replaceSelection(with text: String, _ context: TargetContext) async -> Bool {
        await run(context) { element in
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
        } ?? false
    }

    /// The element the landing captured; nil (and so a refusal) if the context carries none.
    private func run<T: Sendable>(_ context: TargetContext, timeout: Float = AXFieldAccess.timeout, _ body: @Sendable (AXUIElement) -> T) async -> T? {
        guard AXIsProcessTrusted(), let handle = context.elementHandle else { return nil }
        let element = unsafeDowncast(handle.element, to: AXUIElement.self)
        // Own-process elements must be touched on main (AccessibilityFocus "own-process hazard").
        return await AccessibilityFocus.onOwner(of: element) { element -> T? in
            guard let element else { return nil }
            AXUIElementSetMessagingTimeout(element, timeout)
            return body(element)
        }
    }

    private static func range(from value: AXValue) -> FieldRange? {
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
        return FieldRange(location: range.location, length: range.length)
    }

    private static func axValue(_ range: FieldRange) -> AXValue? {
        var cf = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &cf)
    }
}
