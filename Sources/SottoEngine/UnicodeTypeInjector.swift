// Real keystrokes, so a newline here IS Return: always sanitized, never just for terminals
// (CLAUDE.md). Chunks split on scalar boundaries so surrogate pairs never straddle two events.
import ApplicationServices
import SottoCore

public struct UnicodeTypeInjector: TextInjecting {
    private static let chunkLimit = 20

    public init() {}

    public func append(_ text: String, to context: TargetContext) async -> InjectionOutcome {
        guard AXIsProcessTrusted() else { return .failed }
        let source = CGEventSource(stateID: .hidSystemState)
        var chunk: [UInt16] = []

        func flush() async {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            chunk.removeAll(keepingCapacity: true)
            try? await Task.sleep(for: .milliseconds(3))
        }

        for scalar in InjectionText.sanitizeForTerminal(text).unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > Self.chunkLimit { await flush() }
            chunk.append(contentsOf: units)
        }
        await flush()
        return .success
    }
}
