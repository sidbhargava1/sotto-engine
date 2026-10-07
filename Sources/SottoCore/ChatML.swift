// Qwen3 ChatML, rendered by hand (PLAN §6 Phase 2: no enable_thinking switch in llama.cpp's
// template API). Each segment is tokenized separately; only `special` ones parse control tokens,
// so user text can never become one (PB-05).
import Foundation

public struct PromptSegment: Sendable, Equatable {
    public let text: String
    public let special: Bool
    public init(_ text: String, special: Bool = false) {
        self.text = text
        self.special = special
    }
}

public enum ChatML {
    /// The cached part. It ends after the system turn, and the tail opens on `<|im_start|>` — a
    /// special token — so tokenizing prefix and tail apart equals tokenizing them together (PB-06).
    public static func prefix(_ system: String) -> [PromptSegment] {
        [.init("<|im_start|>", special: true), .init("system\n" + system), .init("<|im_end|>", special: true), .init("\n")]
    }

    public static func tail(_ user: String) -> [PromptSegment] {
        [
            .init("<|im_start|>", special: true), .init("user\n" + user), .init("<|im_end|>", special: true), .init("\n"),
            .init("<|im_start|>", special: true), .init("assistant\n"),
        ]
    }

    public static func render(_ segments: [PromptSegment]) -> String { segments.map(\.text).joined() }
}
