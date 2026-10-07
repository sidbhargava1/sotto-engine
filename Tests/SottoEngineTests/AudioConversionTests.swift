// HFP inputs run at 8/16/24 kHz; the converter must upsample as well as downsample (SPEC §5 step 2).
import AVFoundation
import XCTest
@testable import SottoEngine

final class AudioConversionTests: XCTestCase {
    private func tone(_ rate: Double, hz: Double = 440, seconds: Double = 1) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// RMS difference from an ideal 16kHz tone, ignoring the filter's edge samples.
    private func error(_ converted: [Float]) -> Float {
        let ideal = tone(AudioConversion.targetRate)
        let range = 400..<(min(converted.count, ideal.count) - 400)
        let sum = range.reduce(Float(0)) { $0 + pow(converted[$1] - ideal[$1], 2) }
        return (sum / Float(range.count)).squareRoot()
    }

    func test_8kUpsamplesTo16k() throws {
        let out = try AudioConversion.to16kMono(tone(8_000), sourceRate: 8_000)
        XCTAssertEqual(out.count, 16_000, accuracy: 16)
        XCTAssertLessThan(error(out), 0.01)
    }

    func test_24kDownsamplesTo16k() throws {
        let out = try AudioConversion.to16kMono(tone(24_000), sourceRate: 24_000)
        XCTAssertEqual(out.count, 16_000, accuracy: 16)
        XCTAssertLessThan(error(out), 0.01)
    }

    func test_48kStillDownsamples() throws {
        let out = try AudioConversion.to16kMono(tone(48_000), sourceRate: 48_000)
        XCTAssertEqual(out.count, 16_000, accuracy: 16)
        XCTAssertLessThan(error(out), 0.01)
    }

    func test_16kPassesThrough() throws {
        let input = tone(16_000)
        XCTAssertEqual(try AudioConversion.to16kMono(input, sourceRate: 16_000), input)
    }

    func test_downmixMonoIsIdentity() throws {
        let samples: [Float] = [0.1, -0.2, 0.3]
        let buffer = try AudioConversion.pcmBuffer(samples, format: AudioConversion.monoFormat(16_000)!)
        XCTAssertEqual(AudioConversion.downmix(buffer), samples)
    }

    func test_downmixStereoAverages() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let (left, right) = (buffer.floatChannelData![0], buffer.floatChannelData![1])
        (left[0], left[1], right[0], right[1]) = (0.4, -0.2, 0.0, 0.2)
        XCTAssertEqual(AudioConversion.downmix(buffer), [0.2, 0.0])
    }
}
