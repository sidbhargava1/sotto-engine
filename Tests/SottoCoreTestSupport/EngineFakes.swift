// LanguageModelEngine stub and stream collector, shared with SottoInsightsTests.
import Foundation
import SottoCore

/// One token per UTF-8 byte; `pieces` are replayed per request, then end of turn.
final class StubEngine: LanguageModelEngine, @unchecked Sendable {
    private let lock = NSLock()
    var contextSize: Int
    var pieces: [String]
    var tokenDelay: TimeInterval
    var prefillDelay: TimeInterval = 0
    var loadError: Error?
    var endless = false
    /// Staged-prefix support (a second sequence); off by default so in-place rebuild tests stay as they were.
    var staged = false
    var stageDelay: TimeInterval = 0
    private(set) var log: [String] = []
    private var cursor = 0
    private var script: [String] = [] // snapshot per request, so tests can re-script mid-decode

    init(pieces: [String] = ["Hello", " there."], tokenDelay: TimeInterval = 0, contextSize: Int = 8192) { // byte tokens: the ~4KB prompt prefix costs ~4K here
        self.pieces = pieces
        self.tokenDelay = tokenDelay
        self.contextSize = contextSize
    }

    private func record(_ entry: String) { lock.withLock { log.append(entry) } }
    func entries() -> [String] { lock.withLock { log } }

    func load() throws {
        if let loadError { throw loadError }
        record("load")
    }

    func tokenize(_ segments: [PromptSegment]) throws -> [Int32] {
        segments.flatMap { $0.text.utf8.map(Int32.init) }
    }

    func resetAndPrefill(_ tokens: [Int32]) throws {
        if prefillDelay > 0 { Thread.sleep(forTimeInterval: prefillDelay) }
        record("prefill:\(tokens.count)")
        cursor = 0
    }

    func replaceTail(_ tokens: [Int32], after prefixLength: Int) throws {
        record("tail@\(prefixLength)")
        cursor = 0
        script = pieces
    }

    func unload() { record("unload") }

    var supportsStagedPrefix: Bool { staged }
    func beginStagedPrefix(keeping shared: Int) throws { record("stage-begin:\(shared)") }
    func stagePrefill(_ tokens: [Int32], at position: Int) throws {
        if stageDelay > 0 { Thread.sleep(forTimeInterval: stageDelay) }
        record("stage:\(tokens.count)@\(position)")
    }
    func commitStagedPrefix() { record("commit") }
    func discardStagedPrefix() { record("discard") }

    func sampleNext() throws -> String? {
        if tokenDelay > 0 { Thread.sleep(forTimeInterval: tokenDelay) }
        record("sample")
        if endless { return "x" }
        guard cursor < script.count else { return nil }
        defer { cursor += 1 }
        return script[cursor]
    }
}

struct Collected: Sendable {
    let text: String
    let error: (any Error)?
}

func collectStream(_ stream: AsyncThrowingStream<String, Error>) async -> Collected {
    var text = ""
    do {
        for try await piece in stream { text += piece }
        return Collected(text: text, error: nil)
    } catch {
        return Collected(text: text, error: error)
    }
}
