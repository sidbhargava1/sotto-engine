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
}
