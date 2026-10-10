import Foundation
// Draft-free speculative decoding for cleanup (spikes/results/speculative.md): the output is nearly a
// copy of the transcript, so the next few tokens are guessed by copying what follows the last
// generated tokens in the prompt's own tail, then verified by the model in one batch. Pure logic, no
// llama.cpp: the engine supplies the sampler. Greedy verification keeps a draft token only when the
// model would have produced it anyway, so the output equals plain greedy decoding.
public enum CopyAhead {
    /// Tokens of the last `lookup` generated tokens are searched in `source`; the next `length` follow.
    public struct Settings: Sendable, Equatable {
        public var enabled: Bool
        public var lookup: Int
        public var length: Int
        public init(enabled: Bool = true, lookup: Int = 2, length: Int = 6) {
            self.enabled = enabled
            self.lookup = max(1, lookup)
            self.length = max(0, length)
        }
        /// SOTTO_SPECULATION=0 switches it off without a rebuild.
        public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Settings {
            Settings(enabled: env["SOTTO_SPECULATION"] != "0")
        }
        /// Extra KV cells a verify batch may use past the last kept token.
        public var headroom: Int { enabled ? length : 0 }
    }

    /// The draft after `generated`, searching `source` from `cursor` on so a repeated phrase can't pull
    /// the copy backwards. Empty when there is no match. `cursor` moves to the end of the match.
    public static func draft(source: [Int32], generated: [Int32], settings: Settings, cursor: inout Int) -> [Int32] {
        let n = settings.lookup
        guard settings.enabled, settings.length > 0, generated.count >= n, source.count > n else { return [] }
        let tail = generated.suffix(n)
        var j = 0
        while j + n < source.count {  // a match at the very end has nothing to copy
            if j + n >= cursor, source[j..<(j + n)].elementsEqual(tail) {
                cursor = j + n
                return Array(source[(j + n)..<min(j + n + settings.length, source.count)])
            }
            j += 1
        }
        return []
    }

    public struct Resolution: Equatable, Sendable {
        /// Tokens to emit, in order: the model's own choices (accepted drafts, then the first different or bonus one).
        public var emitted: [Int32]
        /// Draft tokens whose KV entries stay (the model agreed with them and they are not the end of turn).
        public var accepted: Int
        public var ended: Bool
    }

    /// `sample(i)` is the model's greedy choice at batch position i (the token after the i-th batch input).
    /// Stops at the first disagreement, after the bonus token when every draft token matched, or at the end of turn.
    public static func resolve(draft: [Int32], sample: (Int) -> Int32, isEnd: (Int32) -> Bool) -> Resolution {
        var emitted: [Int32] = []
        var i = 0
        while true {
            let s = sample(i)
            emitted.append(s)
            if isEnd(s) { return Resolution(emitted: emitted, accepted: i, ended: true) }
            if i < draft.count, s == draft[i] { i += 1 } else { return Resolution(emitted: emitted, accepted: i, ended: false) }
        }
    }
}

extension CopyAhead.Settings {
    /// Off if either side is off; lengths come from `self`.
    public func merged(with other: CopyAhead.Settings) -> CopyAhead.Settings {
        var s = self
        s.enabled = enabled && other.enabled
        return s
    }
}
