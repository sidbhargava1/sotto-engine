// Replace-last (Phase 7 "second chance"): swap the previous dictation for a new one, only where
// the engine can prove it wrote the text it is about to overwrite. The guard and the Accessibility
// sequence live here as plain logic over `FieldAccessing`, so every refusal runs under test with
// no permissions. The session decides when; this file decides whether and how.
import Foundation

/// A UTF-16 range in a text field, the unit Accessibility uses.
public struct FieldRange: Sendable, Equatable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
    var end: Int { location + length }
}

/// Reads and selects text in the element `context.elementHandle` names. There is no way to write
/// the whole value: CLAUDE.md rule 3 (`kAXValue` replaces the field) holds here too.
public protocol FieldAccessing: Sendable {
    /// `kAXSelectedTextRangeAttribute`. nil when unreadable.
    func selectedRange(_ context: TargetContext) async -> FieldRange?
    /// `kAXNumberOfCharactersAttribute`, UTF-16 units. nil when unreadable.
    func characterCount(_ context: TargetContext) async -> Int?
    /// `kAXStringForRangeParameterizedAttribute`. nil when the app doesn't answer.
    func text(in range: FieldRange, _ context: TargetContext) async -> String?
    /// Fallback when `text(in:)` is nil: the same range cut from a read-only `kAXValueAttribute`.
    func valueSubstring(in range: FieldRange, _ context: TargetContext) async -> String?
    /// Moves the selection (caret when `length` is 0). True if the app accepted it.
    func setSelectedRange(_ range: FieldRange, _ context: TargetContext) async -> Bool
    /// Writes `kAXSelectedTextAttribute`. True if the app accepted it.
    func replaceSelection(with text: String, _ context: TargetContext) async -> Bool
}

/// Why a replace was refused. The old text is untouched in every case and the new text is on the
/// clipboard.
public enum ReplaceRefusal: String, Sendable, Equatable, CaseIterable {
    case nothingToReplace, differentField, tooLongAgo, terminal, textChanged, cantCheckField
}

public enum ReplaceMethod: String, Sendable, Equatable {
    /// Select the old range, check it, overwrite, confirm.
    case axVerified
    /// Undo, then paste. Only where the host allows unprovable replaces.
    case paste
}

/// What replace mode did with one utterance. Delivered on `DictationSession.replaceOutcomes()`.
public enum ReplaceOutcome: Sendable, Equatable {
    case replaced(ReplaceMethod)
    /// The new text equals the old one after trimming: nothing was written.
    case sameAsBefore
    /// Old text untouched; the new text is on the clipboard.
    case refused(ReplaceRefusal)
    /// The write was accepted (or may have been) but could not be confirmed. The new text is also on
    /// the clipboard. Not a refusal: the field may have changed.
    case unconfirmed
}

/// What a replace of this landing would do, judged from the landing alone (not focus or time).
public enum ReplacePath: Sendable, Equatable {
    case axVerified
    case paste
    case refuse(ReplaceRefusal)

    /// For logs: no text, just the path.
    public var logName: String {
        switch self {
        case .axVerified: "axVerified"
        case .paste: "paste"
        case .refuse(let reason): "refuse(\(reason.rawValue))"
        }
    }
}

/// The engine's memory of its last landing, in memory only. Never created for a secure field or an
/// excluded app, and cleared on a host signal. Holds the user's words: never log it.
public struct LastLanding: Sendable, Equatable {
    public let bundleID: String?
    public let elementToken: AXElementToken?
    public let isTerminalClass: Bool
    /// The first strategy that landed text; `.clipboard` when nothing reached a field.
    public let strategy: DeliveryKind
    /// Every write went through Accessibility and was confirmed, and the range and count are known.
    public let verified: Bool
    /// Where the text went, read from the field's selection before the first write.
    public let insertedRange: FieldRange?
    /// The field's character count right after the landing.
    public let fieldCount: Int?
    /// What reached the target, after per-target sanitising.
    public let landedText: String
    /// The transcript after dictionary rewrite, before cleanup.
    public let rawText: String
    public let at: ContinuousClock.Instant
    public let date: Date
    /// Injector writes that made up the landing (a raw-text fallback can add a second).
    public let writes: Int
    /// A successful "scratch that" removed this text. Copy Last still has it; replace doesn't.
    public internal(set) var scratched = false
    /// The History row of this landing, when one was queued.
    public internal(set) var recordID: UUID?

    /// Judged from the landing alone; the session adds focus, time and the host's flag.
    public var replacePath: ReplacePath {
        if strategy == .clipboard { return .refuse(.nothingToReplace) }
        if isTerminalClass { return .refuse(.terminal) }
        if strategy == .ax, verified, insertedRange != nil, fieldCount != nil { return .axVerified }
        if strategy == .paste, writes == 1 { return .paste }
        return .refuse(.cantCheckField)
    }
}

/// Why the host is asking the engine to forget the last landing.
public enum LastLandingClearReason: String, Sendable {
    case screenLocked, systemSleep, quit
}

/// A successful "scratch that", so a replace right after it types normally (nothing to remove).
struct LastScratch {
    let bundleID: String?
    let elementToken: AXElementToken?
    let at: ContinuousClock.Instant
}

enum ReplaceResult: Equatable {
    case replaced(ReplaceMethod, fieldCount: Int?)
    case sameAsBefore
    case refused(ReplaceRefusal)
    case unconfirmed
}

/// The guard and the two replace sequences. Pure over its inputs; the session owns the state.
struct ReplaceLast {
    static let window: Duration = .seconds(30)  // same as scratch that (DS-16)

    let fields: (any FieldAccessing)?
    let paste: (any TextInjecting)?
    let undo: any UndoPerforming
    let allowUnprovable: Bool
    /// Asked right before a write: true when the host cleared the last landing meanwhile.
    var abort: @Sendable () async -> Bool = { false }

    private func shouldAbort() async -> Bool { await abort() }

    private func readText(in range: FieldRange, _ fields: any FieldAccessing, _ context: TargetContext) async -> String? {
        if let read = await fields.text(in: range, context) { return read }
        return await fields.valueSubstring(in: range, context)
    }

    /// True only if the selection reads back as the caret: a failed restore would leave the old text
    /// selected, and the next keystroke would delete it.
    private func restoreCaret(_ caret: FieldRange, _ fields: any FieldAccessing, _ context: TargetContext) async -> Bool {
        if await fields.selectedRange(context) == caret { return true }
        _ = await fields.setSelectedRange(caret, context)
        return await fields.selectedRange(context) == caret
    }

    /// The checks that need no field access. nil means go on.
    static func screen(_ rec: LastLanding?, context: TargetContext, focusMoved: Bool, pressedAt: ContinuousClock.Instant) -> ReplaceRefusal? {
        guard let rec, !rec.scratched, rec.strategy != .clipboard else { return .nothingToReplace }
        if rec.isTerminalClass || context.isTerminalClass { return .terminal }
        // nil never matches nil (DS-17).
        guard !focusMoved,
              let bundleID = rec.bundleID, context.bundleID == bundleID,
              let element = rec.elementToken, context.elementToken == element
        else { return .differentField }
        // Press-relative: an earlier utterance still landing when the key went down counts as fresh.
        guard rec.at.duration(to: pressedAt) < window else { return .tooLongAgo }
        return nil
    }

    static func sameText(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func run(_ new: String, over rec: LastLanding, context: TargetContext) async -> ReplaceResult {
        if await shouldAbort() { return .refused(.nothingToReplace) }
        if Self.sameText(new, rec.landedText) { return .sameAsBefore }
        switch rec.replacePath {
        case .refuse(let reason): return .refused(reason)
        case .paste: return await pasteReplace(new, context: context)
        case .axVerified: return await axReplace(new, over: rec, context: context)
        }
    }

    // Undo then paste, back to back. Nothing can be read back, so this is only as safe as the
    // landing being one paste write (one ⌘Z) in the same field under the same window. If undo
    // succeeds and the paste then fails the old text is gone: `.unconfirmed`, and a host label for
    // it must not say the old text was kept.
    private func pasteReplace(_ new: String, context: TargetContext) async -> ReplaceResult {
        guard allowUnprovable, let paste else { return .refused(.cantCheckField) }
        if await shouldAbort() { return .refused(.nothingToReplace) }
        guard await undo.undo(context) else { return .refused(.cantCheckField) }  // nothing was posted
        guard await paste.append(new, to: context) != .failed else { return .unconfirmed }
        return .replaced(.paste, fieldCount: nil)
    }

    // Select the old range, check it still holds exactly what we typed, overwrite, confirm. Every
    // step before the write can abort with the old text in place; there is no put-back.
    private func axReplace(_ new: String, over rec: LastLanding, context: TargetContext) async -> ReplaceResult {
        guard let fields, let range = rec.insertedRange, let oldCount = rec.fieldCount else { return .refused(.cantCheckField) }
        let caret = FieldRange(location: range.end, length: 0)

        guard let count = await fields.characterCount(context), let selection = await fields.selectedRange(context) else { return .refused(.cantCheckField) }
        guard count == oldCount, selection == caret else { return .refused(.textChanged) }
        let current: String?
        if let read = await fields.text(in: range, context) { current = read } else { current = await fields.valueSubstring(in: range, context) }
        guard let current else { return .refused(.cantCheckField) }
        guard current == rec.landedText else { return .refused(.textChanged) }

        guard await fields.setSelectedRange(range, context), await fields.selectedRange(context) == range else {
            return await restoreCaret(caret, fields, context) ? .refused(.cantCheckField) : .unconfirmed
        }
        // A clear (lock, sleep, quit) during the steps above stops the write; nothing has changed yet.
        if await shouldAbort() {
            return await restoreCaret(caret, fields, context) ? .refused(.nothingToReplace) : .unconfirmed
        }
        let newRange = FieldRange(location: range.location, length: new.utf16.count)
        guard await fields.replaceSelection(with: new, context) else {
            // Rejected, but Chromium/Electron often report an error and apply the write a moment
            // later, and new text of the same length leaves the count unchanged. So poll count and
            // text; the old text stands only if it still reads exactly what we typed.
            for attempt in 0..<6 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(20)) }
                let count = await fields.characterCount(context)
                let now = await readText(in: range, fields, context)
                guard count == oldCount, now == rec.landedText else { return .unconfirmed }
            }
            return await restoreCaret(caret, fields, context) ? .refused(.cantCheckField) : .unconfirmed
        }

        let expected = oldCount - range.length + newRange.length
        // Chromium/Electron apply AX writes asynchronously; poll before calling it a miss.
        var after = await fields.characterCount(context)
        var landed = await readText(in: newRange, fields, context)
        for _ in 0..<5 where after != expected || landed != new {
            try? await Task.sleep(for: .milliseconds(20))
            after = await fields.characterCount(context)
            landed = await readText(in: newRange, fields, context)
        }
        guard after == expected, landed == new else { return .unconfirmed }
        _ = await fields.setSelectedRange(FieldRange(location: newRange.end, length: 0), context)
        return .replaced(.axVerified, fieldCount: after)
    }
}
