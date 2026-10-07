// Capture deltas and engine plumbing for live partials (spikes/stream/RESULTS.md wiring list).
import AVFoundation
import SottoCore
import XCTest
@testable import SottoEngine

final class StreamingResamplerTests: XCTestCase {
    private func tone(_ rate: Double, seconds: Double = 1) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / rate)) }
    }

    /// 100 ms chunks through one converter match a single whole-buffer conversion: no seam
    /// glitches, no dropped or duplicated samples.
    func test_chunkedMatchesWhole() throws {
        for rate in [48_000.0, 44_100, 24_000, 8_000] {
            let input = tone(rate)
            let whole = try AudioConversion.to16kMono(input, sourceRate: rate)
            let resampler = try StreamingResampler(sourceRate: rate)
            var chunked: [Float] = []
            let step = Int(rate / 10)
            for start in stride(from: 0, to: input.count, by: step) {
                chunked += try resampler.process(Array(input[start..<min(start + step, input.count)]))
            }
            chunked += try resampler.flush()
            XCTAssertEqual(chunked.count, whole.count, accuracy: 2, "\(rate)")
            let n = min(chunked.count, whole.count)
            let worst = (0..<n).map { abs(chunked[$0] - whole[$0]) }.max() ?? 1
            XCTAssertLessThan(worst, 1e-3, "\(rate)")
        }
    }

    func test_16kPassesThrough() throws {
        let r = try StreamingResampler(sourceRate: 16_000)
        XCTAssertEqual(try r.process([0.1, 0.2]), [0.1, 0.2])
        XCTAssertEqual(try r.flush(), [])
    }
}

final class CaptureChunkCursorTests: XCTestCase {
    private func ramp(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

    func test_deltasFromTheMark_noOverlap() throws {
        var ring = AVAudioEngineCapture.Ring()
        ring.reset(rate: 16_000)
        ring.append(ramp(0..<100))
        ring.mark = 40
        ring.resetChunks(active: true)
        let first = try XCTUnwrap(ring.takeChunkDeltas())
        ring.append(ramp(100..<130))
        let second = try XCTUnwrap(ring.takeChunkDeltas())
        XCTAssertEqual((first + second).flatMap(\.samples), ramp(40..<130))
    }

    /// A Bluetooth restart (PLAN §4) banks the old segment and `reset` zeroes `written`; the pump
    /// must neither drop the unread tail nor re-read audio from the new segment's start.
    func test_restartAtNewRate_keepsEveryUnreadSample() throws {
        var ring = AVAudioEngineCapture.Ring()
        ring.reset(rate: 48_000)
        ring.append(ramp(0..<1_000))
        ring.mark = 200
        ring.resetChunks(active: true)
        var got = try XCTUnwrap(ring.takeChunkDeltas())  // 200..<1000 at 48k
        ring.append(ramp(1_000..<1_300))
        XCTAssertTrue(ring.bankForRestart())
        let beforeMark = try XCTUnwrap(ring.takeChunkDeltas())  // the banked tail, nothing new yet
        XCTAssertEqual(beforeMark.map(\.rate), [48_000])
        got += beforeMark
        ring.reset(rate: 16_000)
        ring.append(ramp(5_000..<5_010))  // tapped before the new mark: not part of the recording
        ring.mark = ring.written
        ring.append(ramp(9_000..<9_050))
        got += try XCTUnwrap(ring.takeChunkDeltas())
        XCTAssertTrue(got.filter { $0.rate == 48_000 }.flatMap(\.samples) == ramp(200..<1_300), "old segment dropped or duplicated")
        XCTAssertTrue(got.filter { $0.rate == 16_000 }.flatMap(\.samples) == ramp(9_000..<9_050), "new segment not from its mark")
    }

    func test_inactiveReturnsNil() {
        var ring = AVAudioEngineCapture.Ring()
        ring.reset(rate: 16_000)
        ring.mark = 0
        XCTAssertNil(ring.takeChunkDeltas())
    }
}

final class SwitchingTranscriberTests: XCTestCase {
    actor Store: ModelStore {
        private(set) var fetched: [ModelID] = []
        private(set) var forced: [ModelID] = []
        func availability(for model: ModelID) -> ModelAvailability { fetched.contains(model) ? .ready : .notDownloaded }
        func ensureDownloaded(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) { fetched.append(model) }
        func ensureDownloaded(_ model: ModelID, force: Bool, progress: @escaping @Sendable (Double) -> Void) {
            if force { forced.append(model) }
            fetched.append(model)
        }
        func url(for model: ModelID) -> URL? { nil }
    }

    final class Engine: PrewarmingTranscriber {
        let name: String
        let store = Store()
        init(_ name: String) { self.name = name }
        var modelSource: ModelSource { ModelSource(store: store, id: ModelID(name)) }
        func prewarm() async throws {
            guard await store.availability(for: ModelID(name)) == .ready else { throw ModelNotDownloaded(ModelID(name)) }
        }
        func transcribe(_ buffer: SottoCore.AudioBuffer) -> AsyncThrowingStream<TranscriptChunk, Error> {
            AsyncThrowingStream { $0.yield(TranscriptChunk(text: self.name)); $0.finish() }
        }
        func partials(_ audio: AsyncStream<SottoCore.AudioBuffer>) -> AsyncThrowingStream<PartialTranscript, Error> {
            AsyncThrowingStream { $0.yield(PartialTranscript(stable: self.name, volatile: "", audioSeconds: 0)); $0.finish() }
        }
    }

    private func first(_ s: AsyncThrowingStream<PartialTranscript, Error>) async throws -> String? {
        for try await p in s { return p.stable }
        return nil
    }

    /// The protocol default would make the wrapper batch-only; it must forward explicitly.
    func test_forwardsPartialsToTheSelectedEngine() async throws {
        let switching = SwitchingTranscriber(.parakeet, parakeet: Engine("parakeet"), apple: Engine("apple"))
        let viaProtocol: any Transcribing = switching
        let silence = AsyncStream<SottoCore.AudioBuffer> { $0.finish() }
        let parakeet = try await first(viaProtocol.partials(silence))
        XCTAssertEqual(parakeet, "parakeet")
        switching.select(.appleSpeechAnalyzer)
        let apple = try await first(viaProtocol.partials(silence))
        XCTAssertEqual(apple, "apple")
    }

    func test_engineForUtteranceIsPinned() async throws {
        let switching = SwitchingTranscriber(.parakeet, parakeet: Engine("parakeet"), apple: Engine("apple"))
        let pinned = switching.engineForUtterance()
        switching.select(.appleSpeechAnalyzer)
        var text = ""
        for try await chunk in pinned.transcribe(SottoCore.AudioBuffer(samples: [0])) { text += chunk.text }
        XCTAssertEqual(text, "parakeet")
    }

    /// ADR §5: prewarm never fetches; only the explicit call does, for the selected engine.
    func test_onlyEnsureDownloadedFetches() async throws {
        let parakeet = Engine("parakeet"), apple = Engine("apple")
        let switching = SwitchingTranscriber(.parakeet, parakeet: parakeet, apple: apple)
        do {
            try await switching.prewarm()
            XCTFail("prewarm must not fetch a missing model")
        } catch let error as ModelNotDownloaded {
            XCTAssertEqual(error.model, ModelID("parakeet"))
        }
        try await switching.ensureDownloaded()
        try await switching.prewarm()
        let parakeetFetched = await parakeet.store.fetched
        let appleFetched = await apple.store.fetched
        XCTAssertEqual(parakeetFetched, [ModelID("parakeet")])
        XCTAssertEqual(appleFetched, [], "only the selected engine's weights")
        let parakeetReady = await switching.modelAvailability()
        XCTAssertEqual(parakeetReady, .ready)
        switching.select(.appleSpeechAnalyzer)
        let appleMissing = await switching.modelAvailability()
        XCTAssertEqual(appleMissing, .notDownloaded)
    }

    /// L1: a forced refetch goes to the selected engine's store only.
    func test_forceReachesTheSelectedStore() async throws {
        let parakeet = Engine("parakeet"), apple = Engine("apple")
        let switching = SwitchingTranscriber(.parakeet, parakeet: parakeet, apple: apple)
        try await switching.ensureDownloaded(force: true)
        let forced = await parakeet.store.forced
        let appleForced = await apple.store.forced
        XCTAssertEqual(forced, [ModelID("parakeet")])
        XCTAssertEqual(appleForced, [])
    }

    /// A store that can't replace its copy treats `force` as a plain fetch (protocol default).
    func test_forceDefaultsToPlainFetch() async throws {
        actor Plain: ModelStore {
            private(set) var fetched = 0
            func availability(for model: ModelID) -> ModelAvailability { .ready }
            func ensureDownloaded(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) { fetched += 1 }
            func url(for model: ModelID) -> URL? { nil }
        }
        let store = Plain()
        try await store.ensureDownloaded(ModelID("x"), force: true) { _ in }
        let fetched = await store.fetched
        XCTAssertEqual(fetched, 1)
    }
}

final class PartialsPowerPolicyTests: XCTestCase {
    func test_offInLowPowerAndHotThermal() {
        XCTAssertTrue(ParakeetTranscriber.partialsAllowed(lowPower: false, thermal: .nominal))
        XCTAssertTrue(ParakeetTranscriber.partialsAllowed(lowPower: false, thermal: .fair))
        XCTAssertFalse(ParakeetTranscriber.partialsAllowed(lowPower: false, thermal: .serious))
        XCTAssertFalse(ParakeetTranscriber.partialsAllowed(lowPower: false, thermal: .critical))
        XCTAssertFalse(ParakeetTranscriber.partialsAllowed(lowPower: true, thermal: .nominal))
    }
}

final class ParakeetStagingTests: XCTestCase {
    /// L1: a refetch killed mid-download leaves `.refetch-*` beside the cache; the next call clears it.
    func test_staleRefetchFoldersAreSwept() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "parakeet-sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = parent.appending(path: "parakeet-tdt-0.6b-v2-coreml", directoryHint: .isDirectory)
        let stale = parent.appending(path: ".refetch-\(UUID().uuidString)", directoryHint: .isDirectory)
        for dir in [cache, stale] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        ParakeetModelStore.sweepStaging(beside: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "the cache itself stays")
    }
}
