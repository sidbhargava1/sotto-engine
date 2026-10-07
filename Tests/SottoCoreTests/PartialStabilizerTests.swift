// Stabilizer and onset gate (spikes/stream/RESULTS.md conditions 1–3), replayed over recorded
// Parakeet hypotheses for the two synthetic (TTS) fixtures in Golden/stream-hypotheses.txt.
// Recordings of real dictation never go in these fixtures; hosts replay their own with RecordedClip.
import SottoCoreTestSupport
import XCTest
@testable import SottoCore

final class PartialStabilizerTests: XCTestCase {
    /// Onsets from the RESULTS.md table (offline RMS > 0.02).
    static let onsets: [String: Double] = ["fixture_15s_a": 0.0, "fixture_5s_a": 0.0]

    func clips() throws -> [RecordedClip] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "stream-hypotheses", withExtension: "txt", subdirectory: "Golden"))
        let clips = RecordedClip.parse(try String(contentsOf: url, encoding: .utf8), onsets: Self.onsets)
        XCTAssertEqual(clips.count, 2)
        return clips
    }

    /// A clip left out of `onsets` drops its ticks; they never extend the clip before it.
    func test_parseSkipsTicksOfUnlistedClips() {
        let text = """
        ### a batch: one two
        0.4s 1ms cpu 1ms | one
        ### b batch: three
        0.4s 1ms cpu 1ms | three
        0.8s 1ms cpu 1ms | three
        ### c batch: four
        0.4s 1ms cpu 1ms | four
        """
        let clips = RecordedClip.parse(text, onsets: ["a": 0, "c": 0])
        XCTAssertEqual(clips.map(\.name), ["a", "c"])
        XCTAssertEqual(clips.map(\.ticks.count), [1, 1])
    }

    private func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map { PartialStabilizer.normalise(String($0)) }
    }

    func test_recordedClips_gateFillerAndCeiling() throws {
        for clip in try clips() {
            let shown = clip.replay()
            XCTAssertFalse(shown.isEmpty, clip.name)
            for p in shown {
                XCTAssertGreaterThanOrEqual(p.audioSeconds, clip.onset + PartialStabilizer.gateAfterOnset, clip.name)
                XCTAssertLessThanOrEqual(p.audioSeconds, PartialStabilizer.maxAudioSeconds, clip.name)
                XCTAssertFalse(p.stable.isEmpty, "nothing shows before the first LA-3 confirmation")
                XCTAssertFalse(PartialStabilizer.isFillerOnly(words(p.stable + " " + p.volatile)), clip.name)
            }
        }
    }

    func test_recordedClips_stableOnlyGrows() throws {
        for clip in try clips() {
            var previous: [String] = []
            for p in clip.replay() {
                let stable = words(p.stable)
                XCTAssertGreaterThanOrEqual(stable.count, previous.count, clip.name)
                XCTAssertEqual(Array(stable.prefix(previous.count)), previous, "\(clip.name) retracted a confirmed word")
                previous = stable
            }
        }
    }

    /// Confirmed text should match the batch transcript almost everywhere.
    func test_recordedClips_confirmedWordsMatchBatch() throws {
        var mismatched = 0, confirmed = 0
        for clip in try clips() {
            guard let last = clip.replay().last else { continue }
            let stable = words(last.stable), batch = words(clip.batch)
            confirmed += stable.count
            mismatched += zip(stable, batch).filter { $0 != $1 }.count
        }
        XCTAssertGreaterThan(confirmed, 60)
        XCTAssertLessThanOrEqual(mismatched, 1)
    }

    func test_ceilingStopsPast14s() {
        var s = PartialStabilizer()
        XCTAssertEqual(s.ingest("so this is long", audioSeconds: 14.4, onset: 0), .stop)
    }

    func test_loneFillerVariantsNeverCountTowardAgreement() {
        for filler in ["Okay.", "OKAY!", "okay", "Ok.", "Yeah?", "yeah", "Mm-hmm.", "mm-hmm", "Mhm.", "Um,", "um", "Uh...", "Okay. Yeah."] {
            var s = PartialStabilizer()
            for t in 1...4 {
                XCTAssertEqual(s.ingest(filler, audioSeconds: 1 + Double(t) * 0.4, onset: 0), .hold, filler)
            }
        }
    }

    func test_fillerFollowedBySpeechIsNotFiltered() {
        var s = PartialStabilizer()
        _ = s.ingest("Okay so", audioSeconds: 1.2, onset: 0)
        _ = s.ingest("Okay so send", audioSeconds: 1.6, onset: 0)
        XCTAssertEqual(s.ingest("Okay so send it", audioSeconds: 2.0, onset: 0),
                       .show(PartialTranscript(stable: "Okay so", volatile: "send it", audioSeconds: 2.0)))
    }

    func test_firstTwoWordsNeedTwoAgreeingHypotheses() {
        var s = PartialStabilizer()
        XCTAssertEqual(s.ingest("Hello", audioSeconds: 1.2, onset: 0), .hold)
        XCTAssertEqual(s.ingest("Hello there", audioSeconds: 1.6, onset: 0),
                       .show(PartialTranscript(stable: "Hello", volatile: "there", audioSeconds: 1.6)))
        XCTAssertEqual(s.ingest("Hello there friend", audioSeconds: 2.0, onset: 0),
                       .show(PartialTranscript(stable: "Hello there", volatile: "friend", audioSeconds: 2.0)))
    }

    func test_wordsPastTheSecondNeedThreeAgreeingHypotheses() {
        var s = PartialStabilizer()
        _ = s.ingest("so I think", audioSeconds: 1.2, onset: 0)
        XCTAssertEqual(s.ingest("so I think we", audioSeconds: 1.6, onset: 0),
                       .show(PartialTranscript(stable: "so I", volatile: "think we", audioSeconds: 1.6)), "LA-2 stops at two words")
        XCTAssertEqual(s.ingest("so I thing we", audioSeconds: 2.0, onset: 0),
                       .show(PartialTranscript(stable: "so I", volatile: "thing we", audioSeconds: 2.0)), "word 3 disagrees in one of three")
        _ = s.ingest("so I think we should", audioSeconds: 2.4, onset: 0)
        XCTAssertEqual(s.ingest("so I think we should", audioSeconds: 2.8, onset: 0), .hold, "\"thing\" is still one of the last three")
        XCTAssertEqual(s.ingest("so I think we should", audioSeconds: 3.2, onset: 0),
                       .show(PartialTranscript(stable: "so I think we should", volatile: "", audioSeconds: 3.2)))
    }

    func test_holdsUntil800msAfterOnset() {
        var s = PartialStabilizer()
        _ = s.ingest("Hello there", audioSeconds: 1.2, onset: 0.8)
        _ = s.ingest("Hello there", audioSeconds: 1.4, onset: 0.8)
        XCTAssertEqual(s.ingest("Hello there", audioSeconds: 1.5, onset: 0.8), .hold, "agreed, but only 0.7 s after onset")
        XCTAssertEqual(s.ingest("Hello there", audioSeconds: 1.6, onset: 0.8),
                       .show(PartialTranscript(stable: "Hello there", volatile: "", audioSeconds: 1.6)))
    }

    func test_holdsWithoutOnset() {
        var s = PartialStabilizer()
        for t in 1...4 { XCTAssertEqual(s.ingest("Hello there", audioSeconds: Double(t), onset: nil), .hold) }
    }

    func test_unchangedSnapshotIsNotRepeated() {
        var s = PartialStabilizer()
        for t in 1...3 { _ = s.ingest("Hello there", audioSeconds: Double(t), onset: 0) }
        XCTAssertEqual(s.ingest("Hello there", audioSeconds: 4, onset: 0), .hold)
    }

    func test_confirmedWordsTakeTheNewestPunctuation() {
        var s = PartialStabilizer()
        for t in 1...3 { _ = s.ingest("Share our research.", audioSeconds: Double(t), onset: 0) }
        XCTAssertEqual(s.ingest("Share our research and", audioSeconds: 4, onset: 0),
                       .show(PartialTranscript(stable: "Share our research", volatile: "and", audioSeconds: 4)))
    }

    func test_disagreeingWordStaysVolatile() {
        var s = PartialStabilizer()
        _ = s.ingest("make sure you see C Sid", audioSeconds: 1, onset: 0)
        _ = s.ingest("make sure you see C Sit", audioSeconds: 2, onset: 0)
        XCTAssertEqual(s.ingest("make sure you see C Sid and", audioSeconds: 3, onset: 0),
                       .show(PartialTranscript(stable: "make sure you see C", volatile: "Sid and", audioSeconds: 3)))
    }
}

final class OnsetDetectorTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * Float(sin(2 * .pi * 220 * Double($0) / 16_000)) }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.001, count: Int(seconds * 16_000)) }

    func test_silenceHasNoOnset() {
        var d = OnsetDetector()
        XCTAssertNil(d.feed(silence(2)))
    }

    func test_speechAtHalfASecond() throws {
        var d = OnsetDetector()
        let onset = try XCTUnwrap(d.feed(silence(0.5) + tone(1)))
        XCTAssertEqual(onset, 0.5, accuracy: 0.021)
    }

    func test_keyClickIsNotOnset() {
        var d = OnsetDetector()
        XCTAssertNil(d.feed(silence(0.2) + tone(0.03, amplitude: 0.8) + silence(1)))
    }

    func test_chunkBoundariesDontMoveOnset() throws {
        let audio = silence(0.37) + tone(1)
        var whole = OnsetDetector(), chunked = OnsetDetector()
        let expected = try XCTUnwrap(whole.feed(audio))
        var found: Double?
        for start in stride(from: 0, to: audio.count, by: 1_600) where found == nil {
            found = chunked.feed(Array(audio[start..<min(start + 1_600, audio.count)]))
        }
        XCTAssertEqual(found, expected)
    }

    func test_quietRoomBelowThreshold() {
        var d = OnsetDetector()
        XCTAssertNil(d.feed(tone(2, amplitude: 0.01)))
    }
}

/// Quiet speech (built-in mic at arm's length, Bluetooth HFP) against the relative onset gate,
/// ui-spec §1.6. Observed 2026-10-06: the absolute −34 dBFS bar opened 3.6–8.8 s late, or never.
final class QuietOnsetTests: XCTestCase {
    private static let rate = 16_000.0

    /// Syllables at ~4 Hz whose 20 ms RMS peaks at `db`, dipping ~20 dB between them; a little noise
    /// underneath at `floorDB`. Deterministic.
    private func utterance(_ seconds: Double, db: Float, floorDB: Float = -60) -> [Float] {
        let peak: Float = powf(10, db / 20) * Float(2).squareRoot()
        let noise: Float = powf(10, floorDB / 20) * Float(3).squareRoot()
        var seed: UInt32 = 7
        var out = [Float](repeating: 0, count: Int(seconds * Self.rate))
        for i in out.indices {
            let t = Double(i) / Self.rate
            let s = sin(Double.pi * 4 * t)
            let envelope = Float(0.1 + 0.9 * s * s)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let u = Float(seed >> 8) / Float(1 << 24)
            let tone = Float(sin(2 * Double.pi * 180 * t))
            out[i] = peak * envelope * tone + (u * 2 - 1) * noise
        }
        return out
    }
    private func room(_ seconds: Double, db: Float = -60) -> [Float] { utterance(seconds, db: -120, floorDB: db) }

    private func onset(_ audio: [Float], detector: OnsetDetector = OnsetDetector()) -> Double? {
        var d = detector
        for start in stride(from: 0, to: audio.count, by: 1_600) where d.onset == nil {
            d.feed(Array(audio[start..<min(start + 1_600, audio.count)]))  // 100 ms chunks, as live
        }
        return d.onset
    }

    func test_minus30dBFS_onsetWithin300ms() throws {
        let start = 0.5
        let at = try XCTUnwrap(onset(room(start) + utterance(3, db: -30)))
        XCTAssertGreaterThanOrEqual(at, start - 0.02)
        XCTAssertLessThanOrEqual(at, start + 0.3)
    }

    func test_minus40dBFS_missedByTheAbsoluteBar_caughtRelatively() throws {
        let audio = room(0.5) + utterance(3, db: -40)
        XCTAssertNil(onset(audio, detector: OnsetDetector(relativeDB: .infinity)), "the old −34 dBFS bar alone")
        XCTAssertLessThanOrEqual(try XCTUnwrap(onset(audio)), 0.8)
    }

    func test_speechFromTheFirstWindow_opensAtTheFirstDip() throws {
        XCTAssertLessThanOrEqual(try XCTUnwrap(onset(utterance(3, db: -38))), 0.5)
    }

    func test_steadyRoomNoise_neverOpens() {
        XCTAssertNil(onset(room(4, db: -44)), "steady noise above the minimum is still the floor")
        XCTAssertNil(onset(room(1, db: -60) + room(3, db: -50)), "a fan starting is a 10 dB step, under the 12 dB bar")
    }

    func test_leadingDigitalZeros_dontSinkTheFloor() {
        XCTAssertNil(onset([Float](repeating: 0, count: 320) + room(4, db: -44)), "20 ms of zeros, then a noisy room")
    }

    func test_belowTheMinimum_neverOpens() {
        XCTAssertNil(onset(room(0.5, db: -75) + utterance(2, db: -50, floorDB: -75)), "−50 dBFS is under −45 even 25 dB clear of the floor")
    }

    /// 0.4 s ticks from onset, as ParakeetTranscriber; a word a tick, as Parakeet on clean speech.
    func test_minus30dBFS_firstPartialWithin1200msOfOnset() throws {
        let at = try XCTUnwrap(onset(room(0.3) + utterance(3, db: -30)))
        let words = ["so", "I", "think", "we", "should", "move", "it"]
        var s = PartialStabilizer()
        var first: Double?
        var tick = (at / 0.4).rounded(.up) * 0.4
        var n = 1
        while first == nil, tick < 3 {
            if case .show(let p) = s.ingest(words.prefix(n).joined(separator: " "), audioSeconds: tick, onset: at) { first = p.audioSeconds }
            tick += 0.4
            n += 1
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(first) - at, 1.2)
    }
}
