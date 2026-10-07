// Qwen3-4B-Instruct-2507 has no thinking mode, but strip <think>…</think> anyway (PLAN §6 Phase 2):
// a reasoning block typed into Slack would be worse than any latency cost. Streaming-safe: a
// trailing "<" is held only until it can't be a tag (LB-03). Leading whitespace is dropped.
import Foundation

struct ThinkStripper {
    private static let open = "<think>", close = "</think>"
    private var held = ""
    private var inThink = false
    private var started = false

    mutating func feed(_ piece: String) -> String {
        held += piece
        var out = ""
        while true {
            let tag = inThink ? Self.close : Self.open
            if let r = held.range(of: tag) {
                if !inThink { out += held[..<r.lowerBound] }
                held = String(held[r.upperBound...])
                inThink.toggle()
                continue
            }
            if !inThink, let r = held.range(of: Self.close) { // stray closer: drop the tag only
                out += held[..<r.lowerBound]
                held = String(held[r.upperBound...])
                continue
            }
            let keep = Self.partialTagSuffix(held, inThink: inThink)
            if !inThink { out += held.dropLast(keep) }
            held = String(held.suffix(keep))
            return trimLeading(out)
        }
    }

    /// LB-04: an unclosed block is dropped whole.
    mutating func finish() -> String {
        defer { held = "" }
        return inThink ? "" : trimLeading(held)
    }

    private static func partialTagSuffix(_ s: String, inThink: Bool) -> Int {
        let tags = inThink ? [close] : [open, close]
        var best = 0
        for tag in tags {
            for k in stride(from: min(tag.count - 1, s.count), through: 1, by: -1) where s.hasSuffix(tag.prefix(k)) {
                best = max(best, k)
                break
            }
        }
        return best
    }

    private mutating func trimLeading(_ text: String) -> String {
        guard !started else { return text }
        let trimmed = String(text.drop(while: \.isWhitespace))
        if !trimmed.isEmpty { started = true }
        return trimmed
    }
}
