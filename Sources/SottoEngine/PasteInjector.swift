// Full per-item pasteboard save/restore (PLAN §4 injection strategy 2). Our write is
// Transient+Concealed; the restore only Transient, so it stays visible but isn't re-recorded.
import AppKit
import SottoCore

public struct PasteInjector: TextInjecting {
    public init() {}

    public func append(_ text: String, to context: TargetContext) async -> InjectionOutcome {
        guard AXIsProcessTrusted() else { return .failed }  // CGEvent posting needs the AX grant
        await ClipboardRestorer.shared.paste(text, restore: context.elementToken != nil)
        // .unverified is reserved for AX read-back (DS-05); a posted ⌘V has nothing to read back.
        return .success
    }
}

// Posts ⌘V and returns at once; the restore runs 500ms later off the dictation path (observed
// 2026-10: 6 × 500ms waits on a 6-word dictation). Back-to-back pastes keep the first snapshot and
// push the restore out, so the user's clipboard comes back exactly once.
actor ClipboardRestorer {
    static let shared = ClipboardRestorer()
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private var snapshot: [[(NSPasteboard.PasteboardType, Data)]]?
    private var pendingRestore: Task<Void, Never>?

    func paste(_ text: String, restore: Bool) {
        let pasteboard = NSPasteboard.general
        pendingRestore?.cancel()
        if snapshot == nil {
            snapshot = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("true", forType: Self.transient)
        pasteboard.setString("true", forType: Self.concealed)
        let ourChange = pasteboard.changeCount
        KeyEvents.post(key: 0x09, flags: .maskCommand)  // ⌘V
        guard restore else { snapshot = nil; return }  // no element to verify: leave it on the clipboard
        pendingRestore = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))  // paste is async in the target
            guard !Task.isCancelled else { return }
            await self?.restore(ifChangeCountIs: ourChange)
        }
    }

    private func restore(ifChangeCountIs ourChange: Int) {
        defer { snapshot = nil; pendingRestore = nil }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == ourChange, let snapshot else { return }  // newer content: leave it
        pasteboard.clearContents()
        let restored = snapshot.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            item.setData(Data("true".utf8), forType: Self.transient)
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

enum KeyEvents {
    /// Flags are always set explicitly so a still-held hotkey modifier can't leak in.
    static func post(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
