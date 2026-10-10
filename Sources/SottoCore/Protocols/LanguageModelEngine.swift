import Foundation

/// Raw token operations on one model context (llama.cpp in the app). Only ever called from
/// `ModelCleanupBackend`'s serial queue, so implementations need no locking of their own.
public protocol LanguageModelEngine: AnyObject, Sendable {
    var contextSize: Int { get }
    /// Weights + context. Seconds; runs once at launch.
    func load() throws
    /// Special segments parse control tokens; the rest never do (PB-05).
    func tokenize(_ segments: [PromptSegment]) throws -> [Int32]
    /// Clears the whole context, then decodes `tokens` from position 0.
    func resetAndPrefill(_ tokens: [Int32]) throws
    /// Drops everything after `prefixLength` (the previous tail), then decodes `tokens`.
    func replaceTail(_ tokens: [Int32], after prefixLength: Int) throws
    /// Greedy-samples one token (decoding the previous one first). Text may be "" mid-UTF-8
    /// sequence; nil = end of turn.
    func sampleNext() throws -> String?
    /// Frees the context and weights; `load()` may run again later.
    func unload()

    // Staged prefix (optional): build a replacement prefix in a second sequence while the live
    // one keeps serving requests, then swap. Engines that don't implement it return false and the
    // backend rebuilds in place.
    var supportsStagedPrefix: Bool { get }
    /// Starts a second sequence that shares the first `keeping` tokens of the live prefix.
    func beginStagedPrefix(keeping shared: Int) throws
    /// Decodes `tokens` into the staged sequence, starting at position `position`.
    func stagePrefill(_ tokens: [Int32], at position: Int) throws
    /// The staged sequence becomes the live one; the old prefix and its tail are dropped.
    func commitStagedPrefix()
    /// Drops the staged sequence; the live one is untouched. No-op when nothing is staged.
    func discardStagedPrefix()
    /// KV cells beyond the tokens it returns that one `sampleNext` may touch (a speculative verify
    /// batch). The backend keeps its context checks this far from the limit. 0 when the engine decodes one token at a time.
    var speculationHeadroom: Int { get }
}

extension LanguageModelEngine {
    public var supportsStagedPrefix: Bool { false }
    public func beginStagedPrefix(keeping shared: Int) throws {}
    public func stagePrefill(_ tokens: [Int32], at position: Int) throws {}
    public func commitStagedPrefix() {}
    public func discardStagedPrefix() {}
    public var speculationHeadroom: Int { 0 }
}
