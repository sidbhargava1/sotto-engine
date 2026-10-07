// llama.cpp in-process (SPEC §6 default). `LlamaEngine` is the raw C-API half of
// `ModelCleanupBackend` (SottoCore), which owns prefix reuse, cancellation and caps; every call
// here arrives on that backend's serial queue, so nothing locks.
import Foundation
import SottoCore
import llama
import os
import Synchronization

/// llama.cpp's own warnings: its log hook is one C callback per process, so it reads this.
private let nativeLog = Mutex(LogSubsystem.engine.logger("llm"))

public enum LlamaBackend {
    /// n_ctx pinned (PLAN §3): the model's trained 256k would allocate gigabytes of KV cache.
    public static func make(modelURL: URL, contextSize: Int = 3072, log: LogSubsystem) -> ModelCleanupBackend {
        let llamaLog = log.logger("llm")
        nativeLog.withLock { $0 = llamaLog }
        return ModelCleanupBackend(engine: LlamaEngine(modelURL: modelURL, contextSize: contextSize), queueLabel: "\(log.name).llm") { event in
            Self.log(event, to: llamaLog)
        }
    }

    // Timings and counts only: transcript and output text never reach the log.
    private static func log(_ event: ModelBackendEvent, to llamaLog: Logger) {
        func ms(_ d: Duration) -> Int { Int((d / .milliseconds(1)).rounded()) }
        switch event {
        case .loaded(let took):
            llamaLog.info("model loaded in \(ms(took), privacy: .public)ms")
        case .prefixReady(let tokens, let took):
            llamaLog.info("prefix ready: \(tokens, privacy: .public) tokens in \(ms(took), privacy: .public)ms")
        case .warmedUp(let took):
            llamaLog.info("warm-up decode in \(ms(took), privacy: .public)ms")
        case .decoded(let tail, let output, let ttft, let tps):
            llamaLog.info("decoded: tail=\(tail, privacy: .public) out=\(output, privacy: .public) ttftMs=\(ttft.map(ms) ?? -1, privacy: .public) tokPerSec=\(Int(tps.rounded()), privacy: .public)")
        case .stopped(let reason):
            llamaLog.notice("decode stopped: \(String(describing: reason), privacy: .public)")
        case .failed(let reason):
            llamaLog.error("llm failed: \(reason, privacy: .public)")
        case .generated(let prompt, let output, let took, let outcome):
            llamaLog.info("narrative: \(outcome, privacy: .public) promptTokens=\(prompt, privacy: .public) out=\(output, privacy: .public) ms=\(ms(took), privacy: .public)")
        }
    }
}

final class LlamaEngine: LanguageModelEngine, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case loadModel(String), createContext, tokenize, decode(Int32)
        var description: String {
            switch self {
            case .loadModel(let path): "could not load \(path)"
            case .createContext: "could not create context"
            case .tokenize: "tokenize failed"
            case .decode(let code): "llama_decode returned \(code)"
            }
        }
    }

    let contextSize: Int
    private let modelURL: URL
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var pendingBytes: [UInt8] = []  // a multi-byte character can span tokens
    private var undecoded: llama_token?     // decoded on the next call, keeping it off TTFT

    private static let backendInit: Void = {
        llama_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            nativeLog.withLock { $0 }.notice("llama.cpp: \(String(cString: text), privacy: .public)")
        }, nil)
        llama_backend_init()
    }()

    init(modelURL: URL, contextSize: Int) {
        self.modelURL = modelURL
        self.contextSize = contextSize
    }

    deinit { unload() }

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (sampler, context, model, vocab) = (nil, nil, nil, nil)
    }

    func load() throws {
        _ = Self.backendInit
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1  // all layers on Metal
        guard let model = llama_model_load_from_file(modelURL.path, modelParams) else {
            throw Failure.loadModel(modelURL.lastPathComponent)
        }
        self.model = model
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = UInt32(contextSize)  // a whole prefix decodes in one call
        guard let context = llama_init_from_model(model, contextParams) else { throw Failure.createContext }
        self.context = context
        vocab = llama_model_get_vocab(model)
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())  // temperature 0
        sampler = chain
    }

    func tokenize(_ segments: [PromptSegment]) throws -> [Int32] {
        var all: [llama_token] = []
        for segment in segments {
            let utf8 = Array(segment.text.utf8CString.dropLast())  // no NUL
            var buffer = [llama_token](repeating: 0, count: utf8.count + 8)
            var n = llama_tokenize(vocab, utf8, Int32(utf8.count), &buffer, Int32(buffer.count), false, segment.special)
            if n < 0 {
                buffer = [llama_token](repeating: 0, count: Int(-n))
                n = llama_tokenize(vocab, utf8, Int32(utf8.count), &buffer, Int32(buffer.count), false, segment.special)
            }
            guard n >= 0 else { throw Failure.tokenize }
            all += buffer.prefix(Int(n))
        }
        return all
    }

    func resetAndPrefill(_ tokens: [Int32]) throws {
        llama_memory_clear(llama_get_memory(context), true)
        try decode(tokens)
    }

    func replaceTail(_ tokens: [Int32], after prefixLength: Int) throws {
        llama_memory_seq_rm(llama_get_memory(context), 0, Int32(prefixLength), -1)
        llama_sampler_reset(sampler)
        pendingBytes = []
        undecoded = nil
        try decode(tokens)
    }

    func sampleNext() throws -> String? {
        if let previous = undecoded { try decode([previous]) }
        let token = llama_sampler_sample(sampler, context, -1)
        undecoded = nil
        if llama_vocab_is_eog(vocab, token) { return nil }
        undecoded = token
        pendingBytes += piece(token)
        let valid = UTF8Prefix.completeLength(pendingBytes)
        defer { pendingBytes.removeFirst(valid) }
        return String(decoding: pendingBytes.prefix(valid), as: UTF8.self)
    }

    private func decode(_ tokens: [Int32]) throws {
        var tokens = tokens
        let code = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard code == 0 else { throw Failure.decode(code) }
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }
}
