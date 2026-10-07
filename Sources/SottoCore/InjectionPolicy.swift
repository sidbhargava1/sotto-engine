// Picks the FIRST strategy to try; `DictationSession` falls further down the `InjectorChain` on
// `.failed` only, never on `.unverified` (DS-05). Doesn't probe runtime AX support (IP-04) — that's
// the injector's job. A protocol so a host (e.g. a sandboxed build) can classify differently
// (ADR §3); `DefaultInjectionPolicy` is Sotto's.
import Foundation

public protocol InjectionPolicy: Sendable {
    /// The first strategy to try for this target; the chain supplies the fallbacks.
    func strategy(for context: TargetContext, overrides: [String: InjectionStrategy]) -> InjectionStrategy
    /// Merges the press-time app and the release-time read into the target, and says whether
    /// focus moved off the press-time app before release (DS-06: then the text goes to the clipboard).
    func resolveTarget(pressApp: String?, release: TargetContext) -> (context: TargetContext, focusMoved: Bool)
}

extension InjectionPolicy {
    public func strategy(for context: TargetContext) -> InjectionStrategy { strategy(for: context, overrides: [:]) }
}

public struct DefaultInjectionPolicy: InjectionPolicy {
    /// Terminal-class apps: injection policy and the voice profile's Agent prompts context both
    /// read this one list (VP-12).
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    ]

    /// The host app's own bundle ID: its windows being frontmost at release is never a focus move.
    /// nil: no app is treated as the host.
    public let hostBundleID: String?

    public init(hostBundleID: String? = nil) {
        self.hostBundleID = hostBundleID
    }

    /// Per-app override wins (IP-03). Terminal-class targets start at `.unicodeType` — paste
    /// semantics vary across terminal emulators (CLAUDE.md, IP-01). Everything else starts at
    /// `.axSelectedText` (IP-02).
    public func strategy(for context: TargetContext, overrides: [String: InjectionStrategy]) -> InjectionStrategy {
        if let bundleID = context.bundleID, let override = overrides[bundleID] {
            return override
        }
        return context.isTerminalClass ? .unicodeType : .axSelectedText
    }

    /// Hotkey-down classification (CLAUDE.md): the target is the app that had typing focus at
    /// press, not the frontmost app at release; iTerm2's hotkey window takes keys without ever
    /// becoming frontmost. `release` supplies the element and the moved check: focus moved when
    /// the release focus owner differs from the press app. Frontmost stands in only when the owner
    /// is unknown, so a known panel owner can't false-positive but a switch to an app with no
    /// readable focus still counts. Unknown on either side is not a move, and a frontmost host app
    /// counts as unknown (its own windows can be frontmost at release). Fail safe:
    /// terminal-class if any of the three apps is.
    public func resolveTarget(pressApp: String?, release: TargetContext) -> (context: TargetContext, focusMoved: Bool) {
        let owner = release.focusOwnerBundleID
        let releaseApp = owner ?? release.bundleID.flatMap { $0 == hostBundleID ? nil : $0 }
        let moved = pressApp != nil && releaseApp != nil && pressApp != releaseApp
        // Nothing at release (no frontmost app, no focus owner) stays "no target" (DS-06): clipboard.
        let noTarget = release.bundleID == nil && owner == nil
        let terminal = release.isTerminalClass || [pressApp, owner].contains { $0.map(Self.terminalBundleIDs.contains) ?? false }
        let context = TargetContext(
            bundleID: noTarget ? nil : pressApp ?? owner ?? release.bundleID,
            isTerminalClass: terminal,
            elementToken: release.elementToken,
            accessibilityGranted: release.accessibilityGranted,
            isSecureInput: release.isSecureInput,
            elementHandle: release.elementHandle,
            focusOwnerBundleID: owner
        )
        return (context, moved)
    }
}

/// Per-target text shaping. Not part of `InjectionPolicy`: never typing Return into a terminal is a
/// safety rule (CLAUDE.md), not a policy a host gets to swap out.
public enum InjectionText {
    /// Drops spaces/tabs before a line break: the model sometimes ends list lines with a markdown
    /// hard break ("  \n"). Line breaks themselves survive (SPEC §14: lists land as real lines).
    public static func trimLineEnds(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for i in lines.indices.dropLast() { // the last segment isn't followed by a break
            while let last = lines[i].last, last == " " || last == "\t" { lines[i] = lines[i].dropLast() }
        }
        return lines.joined(separator: "\n")
    }

    /// Newline/tab -> single space, including doubled newlines (IP-05); never emits Return
    /// (CLAUDE.md). Ported from `spikes/Sources/spike/InjectCommand.swift`.
    public static func sanitizeForTerminal(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { $0.value != 0x2028 && $0.value != 0x2029 }
        var result = String.UnicodeScalarView()
        var pendingBreak = false
        for scalar in scalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                pendingBreak = true
                continue
            }
            if pendingBreak {
                result.append(" ")
                pendingBreak = false
            }
            result.append(scalar)
        }
        if pendingBreak, !result.isEmpty {
            result.append(" ")
        }
        return String(result)
    }
}
