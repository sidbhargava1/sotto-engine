import AppKit
import SottoCore

public struct PasteboardClipboard: ClipboardWriting {
    public init() {}

    // Deliberately not Transient-marked: this is the "no target, paste it yourself" path.
    public func copy(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The 30s/same-element guard is DictationSession's; this only fires the keystroke.
public struct SystemUndo: UndoPerforming {
    public init() {}

    public func undo(_ context: TargetContext) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        KeyEvents.post(key: 0x06, flags: .maskCommand)  // ⌘Z
        return true
    }
}
