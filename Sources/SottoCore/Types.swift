// Pure value types — no I/O, no system framework imports (CLAUDE.md: SottoCore must never
// import AppKit/AVFoundation/CoreML).
import Foundation

public struct AudioBuffer: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Set by the capture when the input delivered only digital silence (AudioWake.isDigitalSilence):
    /// a failed utterance then says "No audio from {device}" instead of "Didn't catch that".
    public var silentInput: SilentInput?

    public struct SilentInput: Sendable, Equatable {
        public var device: String?  // name, for display; nil when unknown
        public init(device: String?) { self.device = device }
    }

    public init(samples: [Float], sampleRate: Double = 16_000, silentInput: SilentInput? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.silentInput = silentInput
    }

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    public var isEmpty: Bool { samples.isEmpty }
}

public struct TranscriptChunk: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool = true) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Boxes an app-target AX element identity (SottoCore can't import ApplicationServices) so
/// "is this still the element we wrote to" (guarded scratch-that, DS-14..17) is testable here.
// @unchecked: callers box simple value identifiers (Int/String hashes of an AXUIElement), never
// a reference type that would make this unsafe to share across actors.
public struct AXElementToken: Equatable, Hashable, @unchecked Sendable {
    private let boxed: AnyHashable
    public init(_ boxed: AnyHashable) { self.boxed = boxed }
}

/// The AX element a provider captured, so the post-landing secure re-check reads that same
/// element instead of re-fetching focus. Equal by identity.
// @unchecked: wraps an immutable AXUIElement (a CFType); AX calls are thread-safe.
public final class AXElementHandle: @unchecked Sendable, Equatable {
    public let element: AnyObject
    public init(_ element: AnyObject) { self.element = element }
    public static func == (lhs: AXElementHandle, rhs: AXElementHandle) -> Bool { lhs === rhs }
}

public struct TargetContext: Sendable, Equatable {
    public let bundleID: String?
    public let isTerminalClass: Bool
    public let elementToken: AXElementToken?
    public let accessibilityGranted: Bool
    /// SPEC §15.1 exclusions (a)/(b). Providers set it true when the probe fails (fail closed).
    public let isSecureInput: Bool
    public let elementHandle: AXElementHandle?
    /// The app that owns the focused element (nil when unknown). Differs from `bundleID` (the
    /// frontmost app) for a non-activating panel such as iTerm2's hotkey window.
    public let focusOwnerBundleID: String?

    public init(bundleID: String?, isTerminalClass: Bool, elementToken: AXElementToken?, accessibilityGranted: Bool, isSecureInput: Bool = false, elementHandle: AXElementHandle? = nil, focusOwnerBundleID: String? = nil) {
        self.bundleID = bundleID
        self.isTerminalClass = isTerminalClass
        self.elementToken = elementToken
        self.accessibilityGranted = accessibilityGranted
        self.isSecureInput = isSecureInput
        self.elementHandle = elementHandle
        self.focusOwnerBundleID = focusOwnerBundleID
    }

    // A frontmost app is enough to attempt injection: terminals are typed into without AX, and
    // browsers often expose no focused element until asked. The chain falls back to the clipboard.
    public var hasEditableTarget: Bool { bundleID != nil }
}

/// Order is AX -> paste -> unicode; terminal-class targets start at `.unicodeType` (CLAUDE.md).
public enum InjectionStrategy: String, Sendable, Equatable, CaseIterable {
    case axSelectedText
    case paste
    case unicodeType
}

/// `.unverified` != `.failed` (DS-05): AX reported success but the char-count read-back couldn't
/// confirm it, so falling back to paste risks a double-insert. Only `.failed` triggers fallback.
public enum InjectionOutcome: Sendable, Equatable {
    case success
    case unverified
    case failed
}

public struct CleanupRequest: Sendable, Equatable {
    public let rawTranscript: String
    public let dictionary: [String]
    public let targetContext: TargetContext

    public init(rawTranscript: String, dictionary: [String], targetContext: TargetContext) {
        self.rawTranscript = rawTranscript
        self.dictionary = dictionary
        self.targetContext = targetContext
    }
}

/// `prefix` must be byte-identical across bundle IDs (SPEC §8 cache boundary); `tail` carries
/// bundle ID + transcript. Unused until Phase 2 wires a real cleanup backend.
public struct Prompt: Sendable, Equatable {
    public let prefix: String
    public let tail: String
    public init(prefix: String, tail: String) {
        self.prefix = prefix
        self.tail = tail
    }
}

public enum Command: Sendable, Equatable {
    case scratchThat
}

public struct DictionaryTerm: Sendable, Equatable, Hashable, Codable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

public enum HotkeyEvent: Sendable, Equatable {
    /// The dictation key. It always dictates.
    case pressed
    case released
    /// The command key: command mode from key-down, and the confirm tap for a pending Shortcut.
    case commandPressed
    case commandReleased
}

/// Drives the floating indicator (docs/ui-spec.md §1.4). `DictationSession` is the only writer.
public enum SessionState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case cleaning
    case injecting
    case degraded(DegradedReason)
    case error(ErrorReason)
    case undone
}

/// Raw values are the history `degraded` column (SPEC §15.2).
public enum DegradedReason: String, Sendable, Equatable {
    case rawTyped = "raw_typed"
    case cleanupTruncated = "cleanup_truncated"  // LB-06: output cap hit; what was typed stands
    case copiedNoTarget = "copied_no_target"
    case copiedNoAX = "copied_no_ax"
    case injectionUnverified = "injection_unverified"
}

public enum ErrorReason: Sendable, Equatable {
    case micDenied
    case micLost
    case sttFailed
    /// The STT engine's weights aren't on disk (`ModelNotDownloaded`): the host fetches them, and
    /// the user isn't told they mumbled.
    case modelMissing
    /// No speech, and the input delivered only digital silence: its device name, if known.
    case silentInput(device: String?)
    case undoRefused
}

/// Thrown by cleanup backends. Anything else is treated the same as `.modelFailed`.
public enum CleanupError: Error, Sendable, Equatable {
    case notReady          // weights or first prefix not loaded yet (LB-11): go raw at once
    case superseded        // a newer request took the context (LB-02)
    case outputCapReached  // max_tokens without EOS (LB-06)
    case contextOverflow   // prefix + tail + cap > n_ctx (LB-07)
    case modelFailed(String)
}

/// One line per dictation in the `latency` log (docs/phase2-test-scenarios.md §B).
public struct UtteranceTiming: Sendable, Equatable {
    public var releaseToFirstInject: Duration?
    public var stt: Duration
    public var ttft: Duration?
    public var total: Duration
    public var words: Int
}
