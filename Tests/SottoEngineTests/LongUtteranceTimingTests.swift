// Batch STT wall time for a long single utterance (a diverted hold can run minutes). Needs the
// Parakeet model on disk and a 16 kHz mono WAV; skipped otherwise.
import SottoCore
import XCTest
@testable import SottoEngine

final class LongUtteranceTimingTests: XCTestCase {
    func test_batchSTTWallTime_longWav() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOTTO_STT_LONG_WAV"] else { throw XCTSkip("set SOTTO_STT_LONG_WAV") }
        let samples = try AudioConversion.loadFile(URL(fileURLWithPath: path))
        let buffer = AudioBuffer(samples: samples, sampleRate: AudioConversion.targetRate)
        let engine = ParakeetTranscriber(models: ParakeetModelStore(), log: .engine)
        try await engine.prewarm()
        for run in 1...3 {
            let start = ContinuousClock.now
            var text = ""
            for try await chunk in engine.transcribe(buffer) { text += chunk.text }
            let took = ContinuousClock.now - start
            print("STT_TIMING run=\(run) audio_s=\(Double(samples.count) / AudioConversion.targetRate) wall=\(took) words=\(text.split(separator: " ").count)")
            XCTAssertFalse(text.isEmpty)
        }
    }
}
