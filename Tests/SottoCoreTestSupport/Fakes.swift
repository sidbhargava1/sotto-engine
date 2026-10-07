// Fakes for DictationSession end-to-end tests (PLAN §7). All zero-permission, zero-I/O.
// A library target (not a test target) so SottoInsightsTests can share them via @testable import.
import Foundation
import Synchronization
import SottoCore

actor FakeHotkeyMonitor: HotkeyMonitoring {
    private let stream: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    init() {
        var cont: AsyncStream<HotkeyEvent>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    private(set) var yielded = 0

    nonisolated func events() -> AsyncStream<HotkeyEvent> { stream }
    func press() { yielded += 1; continuation.yield(.pressed) }
    func release() { yielded += 1; continuation.yield(.released) }
}

actor FixtureAudioCapture: AudioCapturing {
    private var startError: Error?
    private var stopError: Error?
    private var buffers: [AudioBuffer]

    init(buffers: [AudioBuffer] = [AudioBuffer(samples: [0.1, 0.2, 0.3])]) {
        self.buffers = buffers
        events = EventLog<String>()
    }

    func setStartError(_ error: Error?) { startError = error }
    func setStopError(_ error: Error?) { stopError = error }
    func enqueue(_ buffer: AudioBuffer) { buffers.append(buffer) }

    /// Every call in order, so idle-sleep tests can assert sleep/wake placement.
    private(set) var calls: [String] = []

    func start() async throws {
        calls.append("start")
        if let startError { throw startError }
    }

    private var holdsSleep = false
    private var sleepGate: CheckedContinuation<Void, Never>?

    /// Makes the next `sleep()` block until `openSleepGate()`, like a slow engine stop.
    func holdNextSleep() { holdsSleep = true }
    func openSleepGate() {
        holdsSleep = false
        sleepGate?.resume()
        sleepGate = nil
    }

    func sleep() async {
        calls.append("sleep")
        if holdsSleep { await withCheckedContinuation { sleepGate = $0 } }
    }
    func wake() async throws { calls.append("wake") }

    private var transport: AudioTransport = .builtIn
    func setTransport(_ transport: AudioTransport) { self.transport = transport }
    func inputTransport() async -> AudioTransport { transport }

    func stop() async throws -> AudioBuffer {
        calls.append("stop")
        events.append("audio.stop")
        chunkSink.withLock { $0 }?.finish()
        if let stopError { throw stopError }
        return buffers.isEmpty ? AudioBuffer(samples: [0.1, 0.2, 0.3]) : buffers.removeFirst()
    }

    /// Shared with a transcriber so a test can assert cross-adapter ordering.
    nonisolated let events: EventLog<String>
    private nonisolated let chunkSink = Mutex<AsyncStream<AudioBuffer>.Continuation?>(nil)

    init(buffers: [AudioBuffer] = [AudioBuffer(samples: [0.1, 0.2, 0.3])], events: EventLog<String>) {
        self.buffers = buffers
        self.events = events
    }

    /// Like the real capture: one subscriber; `stop()` finishes it. Tests push deltas.
    nonisolated func chunks() -> AsyncStream<AudioBuffer> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioBuffer.self)
        let previous = chunkSink.withLock { sink in
            defer { sink = continuation }
            return sink
        }
        previous?.finish()
        events.append("audio.chunks")
        return stream
    }

    nonisolated func pushChunk(_ buffer: AudioBuffer = AudioBuffer(samples: [Float](repeating: 0.1, count: 1600))) {
        chunkSink.withLock { $0 }?.yield(buffer)
    }
}

actor FixtureTranscriber: Transcribing {
    enum Behavior { case text(String), fail(Error) }
    /// Partials: none (batch default), one snapshot per pushed chunk, never yield until cancelled
    /// (a call in flight at release), or fail on the first chunk.
    enum Partials: Sendable { case batchOnly, perChunk([PartialTranscript]), hang, fail(FakeError), yieldThenFail([PartialTranscript], FakeError) }
    private var behaviors: [Behavior]
    private var warmup: Duration
    private nonisolated let partialScript: Partials
    nonisolated let events: EventLog<String>

    /// `warmup` delays the first transcription only, like a model still loading (DS-01).
    init(_ behaviors: [Behavior] = [.text("hello world")], warmup: Duration = .zero, partials: Partials = .batchOnly, events: EventLog<String> = EventLog<String>()) {
        self.behaviors = behaviors
        self.warmup = warmup
        self.partialScript = partials
        self.events = events
    }

    nonisolated func partials(_ audio: AsyncStream<AudioBuffer>) -> AsyncThrowingStream<PartialTranscript, Error> {
        let (script, events) = (partialScript, events)
        if case .batchOnly = script { return AsyncThrowingStream { $0.finish() } }
        return AsyncThrowingStream { continuation in
            events.append("partials.start")
            let task = Task {
                var index = 0
                for await _ in audio {
                    switch script {
                    case .batchOnly: break
                    case .perChunk(let snapshots):
                        if index < snapshots.count { continuation.yield(snapshots[index]) }
                    case .hang:
                        events.append("partials.inFlight")
                        try? await Task.sleep(for: .seconds(3600))
                    case .fail(let error):
                        continuation.finish(throwing: error)
                        return
                    case .yieldThenFail(let snapshots, let error):
                        if index < snapshots.count { continuation.yield(snapshots[index]) } else {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    index += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { events.append("partials.cancelled") }
                task.cancel()
            }
        }
    }

    private func takeWarmup() -> Duration {
        defer { warmup = .zero }
        return warmup
    }

    func enqueue(_ behavior: Behavior) { behaviors.append(behavior) }

    nonisolated func transcribe(_ buffer: AudioBuffer) -> AsyncThrowingStream<TranscriptChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                self.events.append("transcribe")
                let warmup = await self.takeWarmup()
                if warmup > .zero { try? await Task.sleep(for: warmup) }
                switch await self.nextBehavior() {
                case .text(let text):
                    if !text.isEmpty { continuation.yield(TranscriptChunk(text: text)) }
                    continuation.finish()
                case .fail(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func nextBehavior() -> Behavior {
        behaviors.isEmpty ? .text("hello world") : behaviors.removeFirst()
    }
}

struct FakeError: Error, Equatable { let label: String }

actor FixtureBackend: CleanupBackend {
    struct Step { let text: String; let delay: Duration; init(_ text: String, after delay: Duration = .zero) { self.text = text; self.delay = delay } }
    enum Ending { case finish, fail(Error) }

    private var steps: [Step]
    private var ending: Ending
    private(set) var calls = 0
    private(set) var requests: [CleanupRequest] = []
    private(set) var cancellations = 0 // consumer dropped the stream before it finished (LB-08)

    init(steps: [Step], ending: Ending = .finish) {
        self.steps = steps
        self.ending = ending
    }

    nonisolated func clean(_ request: CleanupRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let (steps, ending) = await self.begin(request)
                for step in steps {
                    if step.delay > .zero {
                        try? await Task.sleep(for: step.delay)
                    }
                    if Task.isCancelled { return }
                    continuation.yield(step.text)
                }
                switch ending {
                case .finish: continuation.finish()
                case .fail(let error): continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                task.cancel()
                Task { await self.noteCancelled() }
            }
        }
    }

    private func begin(_ request: CleanupRequest) -> ([Step], Ending) {
        calls += 1
        requests.append(request)
        return (steps, ending)
    }

    private func noteCancelled() { cancellations += 1 }
}

actor RecordingInjector: TextInjecting {
    struct Call: Equatable { let text: String; let context: TargetContext }
    private(set) var calls: [Call] = []
    private var outcomes: [InjectionOutcome]
    private let fallback: InjectionOutcome

    init(outcomes: [InjectionOutcome] = [], fallback: InjectionOutcome = .success) {
        self.outcomes = outcomes
        self.fallback = fallback
    }

    func append(_ text: String, to context: TargetContext) async -> InjectionOutcome {
        calls.append(Call(text: text, context: context))
        return outcomes.isEmpty ? fallback : outcomes.removeFirst()
    }

    func injectedText() -> String { calls.map(\.text).joined() }
    func callCount() -> Int { calls.count }
}

actor FakeContextProvider: TargetContextProviding {
    private var context: TargetContext
    /// The hotkey-down app; nil means "the same app the context reports" (nothing moved).
    private let pressApp: String??
    init(_ context: TargetContext, pressApp: String?? = nil) {
        self.context = context
        self.pressApp = pressApp
    }
    func set(_ context: TargetContext) { self.context = context }
    func pressTimeApp() async -> String? { pressApp ?? context.bundleID }
    private(set) var probes: [Bool] = []
    func currentContext(probeSecure: Bool) async -> TargetContext {
        probes.append(probeSecure)
        return context
    }
    func isSecureNow(_ context: TargetContext) async -> Bool { self.context.isSecureInput }
}

actor InMemoryDictionaryStore: DictionaryStore {
    private var terms: [DictionaryTerm]
    init(_ terms: [DictionaryTerm] = []) { self.terms = terms }
    func load() async throws -> [DictionaryTerm] { terms }
    func save(_ terms: [DictionaryTerm]) async throws { self.terms = terms }
}

actor InMemorySettings: SettingsStore {
    private var settings: Settings
    init(_ settings: Settings = Settings()) { self.settings = settings }
    func load() async -> Settings { settings }
    func save(_ settings: Settings) async { self.settings = settings }
    func update(_ transform: (inout Settings) -> Void) { transform(&settings) }
}

actor FakeClipboard: ClipboardWriting {
    private(set) var copied: [String] = []
    func copy(_ text: String) async { copied.append(text) }
}

actor FakeUndo: UndoPerforming {
    private(set) var calls: [TargetContext] = []
    private let result: Bool
    init(result: Bool = true) { self.result = result }
    func undo(_ context: TargetContext) async -> Bool {
        calls.append(context)
        return result
    }
    func callCount() -> Int { calls.count }
}

func makeTestContext(bundleID: String? = "com.test.app", isTerminalClass: Bool = false, hasTarget: Bool = true, axGranted: Bool = true) -> TargetContext {
    TargetContext(
        bundleID: bundleID,
        isTerminalClass: isTerminalClass,
        elementToken: hasTarget ? AXElementToken(UUID()) : nil,
        accessibilityGranted: axGranted
    )
}

/// Records every emitted `SessionState`. The listener runs in its own task, so read it with
/// `settled()` after `drain()` to let the last yields land.
final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [SessionState] = []

    func append(_ state: SessionState) { lock.withLock { states.append(state) } }
    func snapshot() -> [SessionState] { lock.withLock { states } }

    func settled() async -> [SessionState] {
        try? await Task.sleep(for: .milliseconds(50))
        return snapshot()
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset: Duration = .zero

    func advance(_ by: Duration) { lock.withLock { offset += by } }
    func now() -> ContinuousClock.Instant { lock.withLock { base + offset } }
}

/// A generic `HistoryRecording` hook: captures what the session offers, behind a fixed gate.
final class RecordingHistory: HistoryRecording, @unchecked Sendable {
    struct Offer: Equatable { let context: TargetContext; let pressApp: String?; let settings: Settings }
    private let lock = NSLock()
    private let wants: Bool
    private let accepts: Bool
    private var _records: [DictationRecord] = []
    private var _scratched: [UUID] = []
    private var _offers: [Offer] = []

    init(wants: Bool = true, accepts: Bool = true) {
        self.wants = wants
        self.accepts = accepts
    }

    var records: [DictationRecord] { lock.withLock { _records } }
    var scratched: [UUID] { lock.withLock { _scratched } }
    var offers: [Offer] { lock.withLock { _offers } }

    func wantsRecords(_ settings: Settings) -> Bool { wants }
    func shouldRecord(context: TargetContext, pressApp: String?, settings: Settings) -> Bool {
        lock.withLock { _offers.append(Offer(context: context, pressApp: pressApp, settings: settings)) }
        return accepts
    }
    func record(_ record: DictationRecord) { lock.withLock { _records.append(record) } }
    func markScratched(_ id: UUID) { lock.withLock { _scratched.append(id) } }
}

/// Hands out `contexts` in order, repeating the last: lets focus change between the
/// pre-cleanup read and the post-landing re-check (HI-24).
actor SequencedContextProvider: TargetContextProviding {
    private var contexts: [TargetContext]
    private let pressApp: String?
    init(_ contexts: [TargetContext]) {
        self.contexts = contexts
        self.pressApp = contexts.first?.bundleID
    }
    func currentContext(probeSecure: Bool) async -> TargetContext { next() }
    func isSecureNow(_ context: TargetContext) async -> Bool { next().isSecureInput }
    func pressTimeApp() async -> String? { pressApp }  // not part of the sequence
    private func next() -> TargetContext {
        contexts.count > 1 ? contexts.removeFirst() : contexts[0]
    }
}

/// Ordered events for ordering assertions (cross-adapter audio/transcriber calls, timings).
final class EventLog<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []
    func append(_ event: Event) { lock.withLock { events.append(event) } }
    var all: [Event] { lock.withLock { events } }
    func snapshot() -> [Event] { all }
}
