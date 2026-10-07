import XCTest
@testable import SottoCore

final class AudioLevelTests: XCTestCase {
    func test_rmsOfConstantIsItsMagnitude() {
        XCTAssertEqual(AudioLevel.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.rms([Float]()), 0)
    }

    func test_normalisedMapsSilenceSpeechAndClipping() {
        XCTAssertEqual(AudioLevel.normalised(rms: 0), 0)
        XCTAssertEqual(AudioLevel.normalised(rms: 0.001), 0)  // -60 dBFS
        XCTAssertEqual(AudioLevel.normalised(rms: 0.1), 0.8, accuracy: 0.01)  // -20 dBFS
        XCTAssertEqual(AudioLevel.normalised(rms: 1), 1)
    }
}
