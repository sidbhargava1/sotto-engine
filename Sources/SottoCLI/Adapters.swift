// The CLI's own small adapters over the engine's public protocols: one press/release, settings in
// memory, and a sink that stands in for the clipboard so stdout gets the session's own fallbacks.
import Foundation
import SottoCore
import SottoEngine

/// The "hotkey": `run` yields one press and one release.
final class OneShotTrigger: HotkeyMonitoring {
    let (stream, edges) = AsyncStream.makeStream(of: HotkeyEvent.self)
    func events() -> AsyncStream<HotkeyEvent> { stream }
}

actor MemorySettings: SettingsStore {
    private var settings: Settings
    init(_ settings: Settings) { self.settings = settings }
    func load() -> Settings { settings }
    func save(_ settings: Settings) { self.settings = settings }
}

/// The `--dictionary` file, read once at launch so the prefix the model prefilled is the one used.
struct FixedDictionary: DictionaryStore {
    let terms: [DictionaryTerm]
    func load() -> [DictionaryTerm] { terms }
    func save(_ terms: [DictionaryTerm]) {}
}

/// Voice commands are off in the CLI, so nothing ever asks for ⌘Z.
struct NoUndo: UndoPerforming {
    func undo(_ context: TargetContext) async -> Bool { false }
}

/// Collects the result. For stdout and the no-Accessibility clipboard mode it is the session's
/// clipboard: a context with no target app routes the whole result there, raw fallback included.
actor OutputSink: ClipboardWriting {
    private(set) var text = ""
    func copy(_ text: String) { self.text += text }
}

/// stdout mode: no app is targeted, so the session delivers through `OutputSink`. The bundle ID in
/// the cleanup prompt reads "unknown".
struct NoTargetContext: TargetContextProviding {
    func currentContext(probeSecure: Bool) async -> TargetContext {
        TargetContext(bundleID: nil, isTerminalClass: false, elementToken: nil, accessibilityGranted: true, isSecureInput: true)
    }
    func isSecureNow(_ context: TargetContext) async -> Bool { true }
    func pressTimeApp() async -> String? { nil }
}

/// `--inject`: CLI.md types into the app focused when processing finishes, so the press-time read
/// is skipped and `DefaultInjectionPolicy.resolveTarget` takes the release-time focus owner.
struct ReleaseTimeContext: TargetContextProviding {
    let base: WorkspaceContextProvider
    func currentContext(probeSecure: Bool) async -> TargetContext { await base.currentContext(probeSecure: probeSecure) }
    func isSecureNow(_ context: TargetContext) async -> Bool { await base.isSecureNow(context) }
    func pressTimeApp() async -> String? { nil }
}

/// `--inject`: `DefaultInjectionPolicy`, plus the app `sotto` was launched from counts as a
/// terminal. Integrated terminals (VS Code, Cursor, Zed, JetBrains, Hyper, tmux inside them) aren't
/// in the terminal list, and a line break typed back into the launching shell would run a command.
struct LaunchingAppPolicy: InjectionPolicy {
    let launchApp: String?
    let base = DefaultInjectionPolicy()

    func strategy(for context: TargetContext, overrides: [String: InjectionStrategy]) -> InjectionStrategy {
        base.strategy(for: context, overrides: overrides)
    }

    func resolveTarget(pressApp: String?, release: TargetContext) -> (context: TargetContext, focusMoved: Bool) {
        let (context, moved) = base.resolveTarget(pressApp: pressApp, release: release)
        guard let launchApp, !context.isTerminalClass,
              context.bundleID == launchApp || context.focusOwnerBundleID == launchApp
        else { return (context, moved) }
        let terminal = TargetContext(
            bundleID: context.bundleID, isTerminalClass: true, elementToken: context.elementToken,
            accessibilityGranted: context.accessibilityGranted, isSecureInput: context.isSecureInput,
            elementHandle: context.elementHandle, focusOwnerBundleID: context.focusOwnerBundleID
        )
        return (terminal, moved)
    }
}

/// `transcribe`: the file through `FixtureAudioCapture`, cut at the live 60 s cap. nil: a WAV with
/// no frames, which AVAudioFile can't load but is just silence (exit 1, not 66).
final class CappedFileCapture: AudioCapturing {
    static let capSeconds = 60.0
    let file: FixtureAudioCapture?

    init(_ file: FixtureAudioCapture?) { self.file = file }

    var isOverCap: Bool { Double(file?.samples.count ?? 0) > Self.capSeconds * AudioConversion.targetRate }

    func start() async throws { try await file?.start() }
    func stop() async throws -> SottoCore.AudioBuffer {
        guard let buffer = try await file?.stop() else { return SottoCore.AudioBuffer(samples: []) }
        let cap = Int(Self.capSeconds * buffer.sampleRate)
        guard buffer.samples.count > cap else { return buffer }
        return SottoCore.AudioBuffer(samples: Array(buffer.samples.prefix(cap)), sampleRate: buffer.sampleRate)
    }
}

enum WAV {
    /// RIFF/WAVE, or the 64-bit RF64/BW64 variants, by the first 12 bytes.
    static func isWAV(header: Data) -> Bool {
        guard header.count >= 12 else { return false }
        let riff = String(decoding: header.prefix(4), as: UTF8.self)
        let wave = String(decoding: header.dropFirst(8).prefix(4), as: UTF8.self)
        return ["RIFF", "RF64", "BW64"].contains(riff) && wave == "WAVE"
    }
}
