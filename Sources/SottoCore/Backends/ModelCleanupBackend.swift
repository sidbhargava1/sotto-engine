// The local-model cleanup backend (SPEC §6), engine-agnostic so it runs against a stub in tests.
// PLAN §3 consequence 3: prefill the prefix once, keep `prefixLength`, and replace only the tail
// per request. One serial queue owns the context: blocking decode never lands on the cooperative
// pool, and a dictionary re-prefill can never run under an active decode (WR-07).
import Foundation
import Synchronization

public enum ModelBackendEvent: Sendable {
    case loaded(took: Duration)
    case prefixReady(tokens: Int, took: Duration)
    case warmedUp(took: Duration)
    case decoded(tailTokens: Int, outputTokens: Int, ttft: Duration?, tokensPerSecond: Double)
    case stopped(CleanupError)
    /// A request's dictionary didn't match the live prefix; it decoded against the live one while the new one builds.
    case servedOldPrefix
    case failed(String)
    /// The voice-profile narrative (rulings must-fix 5). `outcome` is a fixed word, never text.
    case generated(promptTokens: Int, outputTokens: Int, took: Duration, outcome: String)
}

public actor ModelCleanupBackend: CleanupBackend {
    private let engine: any LanguageModelEngine
    private let queue: DispatchSerialQueue
    private let onEvent: @Sendable (ModelBackendEvent) -> Void
    // Read without hopping onto the queue: a press during the launch load goes raw at once (LB-11)
    // instead of waiting seconds behind it.
    private let ready = Mutex(false)
    private let latestRequest = Mutex(0)
    private let narrativeEpoch = Mutex(0)
    // A count, not a flag: an overlapping generate finishing first mustn't clear the other's busy state.
    private let generating = Mutex(0)
    private var cachedPrefix: String?
    /// What `cachedPrefix` returns to after a narrative borrowed the KV.
    private var dictationPrefix: String?
    private var prefixLength = 0
    private var prefixTokens: [Int32] = []
    // Staged re-prefill (a second sequence). `stagingGeneration` retires a superseded or cancelled
    // build: its loop notices at the next batch and leaves the engine alone.
    private var stagingTarget: String?
    private var stagingTask: Task<Void, Never>?
    private var stagingGeneration = 0
    private var stagedCells = 0
    /// Tokens per staged decode. A request that arrives mid-build waits for at most one batch.
    static let stagingBatch = 64
    /// KV cells kept free for the live tail and output while a second prefix is being staged
    /// (the cap is 2 x tail + 64, so this covers a tail of about 320 tokens, far above a minute of speech).
    public static let stagingReserve = 1024

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// `queueLabel` names the serial queue in crash reports and Instruments; the host picks it.
    public init(engine: any LanguageModelEngine, queueLabel: String = "sotto-engine.llm", onEvent: @escaping @Sendable (ModelBackendEvent) -> Void = { _ in }) {
        self.engine = engine
        self.onEvent = onEvent
        queue = DispatchSerialQueue(label: queueLabel, qos: .userInitiated)
    }

    public nonisolated var isReady: Bool { ready.withLock { $0 } }

    /// Launch pre-warm (PLAN §3 consequence 2): weights, then the prefix.
    public func load(dictionary: [String]) throws {
        let start = ContinuousClock.now
        do {
            try engine.load()
            onEvent(.loaded(took: .now - start))
            try rebuildPrefix(PromptBuilder.prefix(dictionary: dictionary))
            try warmUp()
            ready.withLock { $0 = true }
        } catch {
            onEvent(.failed(String(describing: error)))
            throw error
        }
    }

    /// WR-05: eager re-prefill after a dictionary edit, off the hotkey path. No-op before load.
    /// With a staging-capable engine the old prefix keeps serving requests until the new one is
    /// ready; returns once the swap has happened (or the build was superseded).
    public func prepare(dictionary: [String]) async {
        guard isReady else { return }
        let prefix = PromptBuilder.prefix(dictionary: dictionary)
        if prefix == cachedPrefix {
            if stagingTarget != nil { cancelStaging() }  // the edit was undone
            return
        }
        if cachedPrefix != nil, let building = stage(prefix) {
            await building.value
            return
        }
        do { try rebuildPrefix(prefix) } catch { onEvent(.failed(String(describing: error))) }
    }

    /// Call synchronously first at quit: stops an in-flight decode at its next token, without
    /// waiting for the queue that decode is holding.
    public nonisolated func beginShutdown() {
        ready.withLock { $0 = false }
        latestRequest.withLock { $0 += 1 }
    }

    /// Before process exit: llama.cpp's Metal teardown asserts if a context outlives it.
    public func shutdown() {
        beginShutdown()
        cancelStaging()
        cachedPrefix = nil
        engine.unload()
    }

    /// Hotkey press: stops a narrative at its next token without waiting for the queue it holds.
    /// The caller queues `prepare(dictionary:)` next, so the dictation prefix is back before release.
    public nonisolated func preempt() { narrativeEpoch.withLock { $0 += 1 } }

    /// True from `generate` until its decode ends, so a press only queues a re-prefill when needed.
    public nonisolated var isGenerating: Bool { generating.withLock { $0 > 0 } }

    /// One-off generation on the same context (no second sequence, rulings must-fix 5). A
    /// `preempt()` or any cleanup request ends it with `.superseded`; otherwise the dictation
    /// prefix is re-prefilled before the queue is released.
    public nonisolated func generate(system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        guard isReady else {
            continuation.finish(throwing: CleanupError.notReady)
            return stream
        }
        let epoch = narrativeEpoch.withLock { $0 }
        let request = latestRequest.withLock { $0 }
        generating.withLock { $0 += 1 }
        let task = Task { await self.runGenerate(system: system, user: user, maxTokens: maxTokens, epoch: epoch, request: request, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runGenerate(system: String, user: String, maxTokens: Int, epoch: Int, request: Int, _ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let start = ContinuousClock.now
        var promptTokens = 0, produced = 0
        defer { generating.withLock { $0 -= 1 } }
        func live() throws {
            try Task.checkCancellation()
            if narrativeEpoch.withLock({ $0 }) != epoch || latestRequest.withLock({ $0 }) != request { throw CleanupError.superseded }
        }
        do {
            try live()
            if let pending = stagingTarget { dictationPrefix = pending }  // restore the newest dictionary afterwards
            cancelStaging()
            cachedPrefix = nil  // before the KV changes: nothing may decode against it as a dictation prefix
            let head = try engine.tokenize(ChatML.prefix(system))
            let tail = try engine.tokenize(ChatML.tail(user))
            promptTokens = head.count + tail.count
            guard promptTokens + maxTokens <= engine.contextSize else { throw CleanupError.contextOverflow }
            try engine.resetAndPrefill(head)
            try engine.replaceTail(tail, after: head.count)
            var stripper = ThinkStripper()
            while true {
                try live()
                guard produced < maxTokens else {
                    let rest = stripper.finish()
                    if !rest.isEmpty { continuation.yield(rest) }
                    throw CleanupError.outputCapReached
                }
                guard let piece = try engine.sampleNext() else { break }
                produced += 1
                let text = stripper.feed(piece)
                if !text.isEmpty { continuation.yield(text) }
            }
            let rest = stripper.finish()
            if !rest.isEmpty { continuation.yield(rest) }
            onEvent(.generated(promptTokens: promptTokens, outputTokens: produced, took: .now - start, outcome: "done"))
            restoreDictationPrefix()
            continuation.finish()
        } catch CleanupError.superseded {
            // The press that preempted us queued the re-prefill; doing it here too would double it.
            onEvent(.generated(promptTokens: promptTokens, outputTokens: produced, took: .now - start, outcome: "preempted"))
            continuation.finish(throwing: CleanupError.superseded)
        } catch {
            onEvent(.generated(promptTokens: promptTokens, outputTokens: produced, took: .now - start, outcome: (error as? CleanupError).map { "\($0)" } ?? "failed"))
            restoreDictationPrefix()
            continuation.finish(throwing: error is CancellationError ? CancellationError() : error)
        }
    }

    private func restoreDictationPrefix() {
        guard let dictationPrefix, cachedPrefix != dictationPrefix, isReady else { return }
        do { try rebuildPrefix(dictationPrefix) } catch { onEvent(.failed(String(describing: error))) }
    }

    /// Forgets the cached prefix so the next request re-prefills (the SOTTO_FAULT=drop_prefix check).
    public func invalidatePrefix() { cachedPrefix = nil }

    public nonisolated func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        guard isReady else {
            continuation.finish(throwing: CleanupError.notReady)
            return stream
        }
        let id = latestRequest.withLock { $0 += 1; return $0 } // LB-02: the newest request wins
        let task = Task { await self.run(request, id: id, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ request: CleanupRequest, id: Int, _ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let start = ContinuousClock.now
        do {
            let prompt = PromptBuilder.build(request)
            try checkLive(id)
            // LB-10/WR-06: never decode a tail on a prefix that doesn't match the KV. With staging, a
            // request whose dictionary differs decodes against the live prefix as it is (prompt and KV
            // agree; only the new term is missing, and the heard-as rewrite already applied it) and
            // the backend starts the re-prefill itself. Without it, rebuild first, inside the budget.
            if prompt.prefix != cachedPrefix {
                if cachedPrefix != nil, stage(prompt.prefix) != nil {
                    onEvent(.servedOldPrefix)
                } else {
                    try rebuildPrefix(prompt.prefix)
                }
            }
            let tail = try engine.tokenize(ChatML.tail(prompt.tail))
            let cap = 2 * tail.count + 64
            if stagedCells > 0, prefixLength + stagedCells + tail.count + cap > engine.contextSize { cancelStaging() }
            guard prefixLength + stagedCells + tail.count + cap <= engine.contextSize else { throw CleanupError.contextOverflow }
            try engine.replaceTail(tail, after: prefixLength)

            var stripper = ThinkStripper()
            var produced = 0
            var firstAt: ContinuousClock.Instant?
            while true {
                try checkLive(id)
                guard produced < cap else {
                    let rest = stripper.finish()
                    if !rest.isEmpty { continuation.yield(rest) }
                    throw CleanupError.outputCapReached
                }
                guard let piece = try engine.sampleNext() else { break }
                produced += 1
                let text = stripper.feed(piece)
                if !text.isEmpty {
                    if firstAt == nil { firstAt = .now }
                    continuation.yield(text)
                }
            }
            let rest = stripper.finish()
            if !rest.isEmpty { continuation.yield(rest) }
            let decodeSeconds = firstAt.map { (ContinuousClock.now - $0) / .seconds(1) } ?? 0
            onEvent(.decoded(tailTokens: tail.count, outputTokens: produced, ttft: firstAt.map { $0 - start },
                             tokensPerSecond: decodeSeconds > 0 ? Double(produced) / decodeSeconds : 0))
            continuation.finish()
        } catch let error as CleanupError {
            onEvent(.stopped(error))
            continuation.finish(throwing: error)
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError()) // consumer is gone (LB-08)
        } catch {
            onEvent(.failed(String(describing: error)))
            continuation.finish(throwing: error)
        }
    }

    /// The first decode on a fresh context pays a one-off GPU pipeline cost (~0.4s measured);
    /// pay it at launch, not on the first dictation. The next request replaces this tail.
    private func warmUp() throws {
        let start = ContinuousClock.now
        let tail = try engine.tokenize(ChatML.tail("App: unknown\n<transcript>warm up</transcript>"))
        try engine.replaceTail(tail, after: prefixLength)
        for _ in 0..<2 { _ = try engine.sampleNext() }
        onEvent(.warmedUp(took: .now - start))
    }

    private func checkLive(_ id: Int) throws {
        try Task.checkCancellation()
        if latestRequest.withLock({ $0 }) != id { throw CleanupError.superseded }
    }

    private func rebuildPrefix(_ prefix: String) throws {
        let start = ContinuousClock.now
        cancelStaging()  // a full reset clears every sequence
        cachedPrefix = nil // a failed rebuild must not leave the old text claiming the new KV
        let tokens = try engine.tokenize(ChatML.prefix(prefix))
        try engine.resetAndPrefill(tokens)
        prefixTokens = tokens
        prefixLength = tokens.count
        cachedPrefix = prefix
        dictationPrefix = prefix
        onEvent(.prefixReady(tokens: tokens.count, took: .now - start))
    }

    // MARK: staged re-prefill

    /// The task building `prefix` beside the live one: started, restarted (a newer edit
    /// supersedes an older build) or joined if already running. nil when the engine can't stage or
    /// the second sequence wouldn't fit; the caller rebuilds in place then.
    private func stage(_ prefix: String) -> Task<Void, Never>? {
        guard engine.supportsStagedPrefix, cachedPrefix != nil else { return nil }
        if stagingTarget == prefix, let task = stagingTask { return task }
        cancelStaging()
        guard let tokens = try? engine.tokenize(ChatML.prefix(prefix)) else { return nil }
        var shared = 0
        while shared < min(tokens.count, prefixTokens.count), tokens[shared] == prefixTokens[shared] { shared += 1 }
        // Shared cells are stored once; only the changed part costs extra.
        guard prefixLength + (tokens.count - shared) + Self.stagingReserve <= engine.contextSize else { return nil }
        do { try engine.beginStagedPrefix(keeping: shared) } catch {
            engine.discardStagedPrefix()
            onEvent(.failed(String(describing: error)))
            return nil
        }
        stagingGeneration += 1
        let generation = stagingGeneration
        stagingTarget = prefix
        stagedCells = 0
        let task = Task { await self.runStaging(prefix, tokens, shared: shared, generation: generation) }
        stagingTask = task
        return task
    }

    /// Small batches with a suspension between each, so a queued request runs between two batches
    /// instead of behind the whole prefill. Decodes never interleave with a batch (one queue).
    private func runStaging(_ prefix: String, _ tokens: [Int32], shared: Int, generation: Int) async {
        let start = ContinuousClock.now
        var position = shared
        do {
            while position < tokens.count {
                guard generation == stagingGeneration, isReady else { return }
                let end = min(position + Self.stagingBatch, tokens.count)
                try engine.stagePrefill(Array(tokens[position..<end]), at: position)
                stagedCells += end - position
                position = end
                await Task.yield()
            }
            guard generation == stagingGeneration, isReady else { return }
            engine.commitStagedPrefix()
            prefixTokens = tokens
            prefixLength = tokens.count
            cachedPrefix = prefix
            dictionaryPrefixSwapped(prefix)
            onEvent(.prefixReady(tokens: tokens.count, took: .now - start))
        } catch {
            guard generation == stagingGeneration else { return }
            cancelStaging()
            onEvent(.failed(String(describing: error)))
        }
    }

    private func dictionaryPrefixSwapped(_ prefix: String) {
        dictationPrefix = prefix
        stagingTarget = nil
        stagingTask = nil
        stagedCells = 0
        stagingGeneration += 1
    }

    private func cancelStaging() {
        guard stagingTarget != nil else { return }
        stagingGeneration += 1
        stagingTask?.cancel()
        stagingTask = nil
        stagingTarget = nil
        stagedCells = 0
        engine.discardStagedPrefix()
    }
}
