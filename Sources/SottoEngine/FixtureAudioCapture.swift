// `--fixture <wav>`: proves the pipeline end to end without a mic or a voice (PLAN §4 table).
import Foundation
import SottoCore
import Synchronization
import os

public final class FixtureAudioCapture: AudioCapturing, Sendable {
    public let samples: [Float]
    private let log: Logger
    private let chunkSink = Mutex<AsyncStream<SottoCore.AudioBuffer>.Continuation?>(nil)

    public init(url: URL, log: LogSubsystem) throws {
        samples = try AudioConversion.loadFile(url)
        self.log = log.logger("audio")
    }

    public func start() async throws {}
    // Logged so a fixture run shows the session's idle-sleep timing without a real engine.
    public func sleep() async { log.info("fixture audio: sleep") }
    public func wake() async throws { log.info("fixture audio: wake") }

    // Replays the WAV's own loudness at the live rate, looping, so a fixture run shows motion.
    public func levels() -> AsyncStream<Float> {
        let (samples, log) = (samples, log)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                log.info("levels: publishing started (fixture)")
                let chunk = Int(AudioConversion.targetRate / AudioLevel.rate)
                var offset = 0, published = 0
                while !Task.isCancelled, !samples.isEmpty {
                    let end = min(offset + chunk, samples.count)
                    continuation.yield(AudioLevel.normalised(rms: AudioLevel.rms(samples[offset..<end])))
                    published += 1
                    offset = end == samples.count ? 0 : end
                    try? await Task.sleep(for: .seconds(1 / AudioLevel.rate))
                }
                log.info("levels: publishing stopped after \(published, privacy: .public) updates (fixture)")
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // The WAV from its start, in 100 ms deltas at real time like the live pump; then silence
    // (nothing yielded) until stop() finishes it.
    public func chunks() -> AsyncStream<SottoCore.AudioBuffer> {
        let (stream, continuation) = AsyncStream.makeStream(of: SottoCore.AudioBuffer.self)
        chunkSink.withLock { sink in
            defer { sink = continuation }
            return sink
        }?.finish()
        let samples = samples
        let task = Task {
            let step = Int(AudioConversion.targetRate / 10)
            var offset = 0
            while !Task.isCancelled, offset < samples.count {
                try? await Task.sleep(for: .milliseconds(100))
                let end = min(offset + step, samples.count)
                continuation.yield(SottoCore.AudioBuffer(samples: Array(samples[offset..<end]), sampleRate: AudioConversion.targetRate))
                offset = end
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func stop() async throws -> SottoCore.AudioBuffer {
        chunkSink.withLock { sink in
            defer { sink = nil }
            return sink
        }?.finish()
        return SottoCore.AudioBuffer(samples: samples, sampleRate: AudioConversion.targetRate)
    }
}
