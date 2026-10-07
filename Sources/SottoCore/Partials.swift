// Live partials for the mascot bubble (PLAN §6 Phase 6, spikes/stream/RESULTS.md conditions 1–3).
// Pure logic: engines produce raw hypotheses, these decide what the bubble may show.
import Foundation

/// What the bubble shows. A snapshot, not a delta: each value replaces the last.
public struct PartialTranscript: Sendable, Equatable {
    /// Confirmed by agreement (labelColor); only grows within an utterance.
    public var stable: String
    /// Tail the engine may still revise (secondaryLabelColor).
    public var volatile: String
    /// Audio covered, for diagnostics.
    public var audioSeconds: Double

    public init(stable: String, volatile: String, audioSeconds: Double) {
        self.stable = stable
        self.volatile = volatile
        self.audioSeconds = audioSeconds
    }
}

/// Speech onset from RMS over 16 kHz capture chunks. Its own detector because `levels()` has a
/// single subscriber, the meter.
///
/// Relative, not absolute (ui-spec §1.6): a window is loud when it clears the running noise floor by
/// `relativeDB` and sits above `minimumDB`, or clears `threshold` outright. The 0.02 (−34 dBFS) bar
/// alone was tuned on loud fixtures; quiet built-in mics and Bluetooth HFP talk at −35…−45 dBFS
/// and opened the gate seconds late or never (observed 2026-10-06: 3.6–8.8 s).
public struct OnsetDetector: Sendable {
    public static let windowSeconds = 0.02
    static let silentDB: Float = -90

    public let threshold: Float
    public let relativeDB: Float
    public let minimumDB: Float
    public let sustain: Int  // consecutive loud windows; a key click is shorter than 60 ms
    private let window: Int
    private var sum: Float = 0
    private var count = 0
    private var windowsSeen = 0
    private var run = 0
    private var floor = LevelFollower.floor()
    /// Seconds from the capture mark to the start of the first sustained loud run.
    public private(set) var onset: Double?

    public init(threshold: Float = 0.02, relativeDB: Float = 12, minimumDB: Float = -45, sustain: Int = 3, sampleRate: Double = 16_000) {
        self.threshold = threshold
        self.relativeDB = relativeDB
        self.minimumDB = minimumDB
        self.sustain = max(sustain, 1)
        window = max(Int(sampleRate * Self.windowSeconds), 1)
    }

    @discardableResult
    public mutating func feed(_ samples: [Float]) -> Double? {
        guard onset == nil else { return onset }
        for s in samples {
            sum += s * s
            count += 1
            guard count == window else { continue }
            let rms = (sum / Float(window)).squareRoot()
            sum = 0
            count = 0
            windowsSeen += 1
            let db = 20 * log10(max(rms, 1e-6))
            // Compared with the floor before this window joins it; the first window only sets it.
            let aboveFloor = floor.value.map { db >= minimumDB && Double(db) >= $0 + Double(relativeDB) } ?? false
            // Digital zeros (engine start, HFP settle) aren't room noise: they'd sink the floor for seconds.
            if db > Self.silentDB { floor.next(Double(db), dt: Self.windowSeconds) }
            run = rms > threshold || aboveFloor ? run + 1 : 0
            if run == sustain {
                onset = Double(windowsSeen - sustain) * Self.windowSeconds
                return onset
            }
        }
        return nil
    }
}

/// LocalAgreement-3 over successive hypotheses, with the onset gate and lone-filler guard
/// (RESULTS.md conditions 1–2) and the 14 s ceiling (condition 3: stitching not built yet).
/// The first `earlyWords` confirm on LA-2, so a word shows about one tick sooner (ui-spec §1.6).
public struct PartialStabilizer: Sendable {
    public static let agreement = 3
    public static let earlyAgreement = 2
    public static let earlyWords = 2
    public static let gateAfterOnset = 0.8
    public static let maxAudioSeconds = 14.0
    /// Parakeet invents these on near-silent prefixes (RESULTS.md condition 1), normalised.
    static let fillers: Set<String> = ["okay", "ok", "yeah", "mmhmm", "mhm", "mm", "hmm", "um", "umm", "uh"]

    public enum Output: Sendable, Equatable {
        case hold
        case show(PartialTranscript)
        /// Past the ceiling: the stream should finish and the bubble hide until the transcript.
        case stop
    }

    private var history: [[String]] = []
    private var committed: [String] = []  // display form of the confirmed words
    private var lastShown: (stable: String, volatile: String)?

    public init() {}

    public mutating func ingest(_ hypothesis: String, audioSeconds: Double, onset: Double?) -> Output {
        guard audioSeconds < Self.maxAudioSeconds else { return .stop }
        let words = hypothesis.split(whereSeparator: \.isWhitespace).map(String.init)
        // Punctuation-only ("...", "—") is as empty as whitespace: ignored, never breaks an agreement run.
        let spoken = words.filter { !Self.normalise($0).isEmpty }
        guard !spoken.isEmpty, !Self.isFillerOnly(spoken) else { return .hold }

        history.append(words)
        if history.count > Self.agreement { history.removeFirst() }
        var agreed = history.count == Self.agreement ? Self.commonPrefixLength(history) : 0
        if committed.count < Self.earlyWords, history.count >= Self.earlyAgreement {
            agreed = max(agreed, min(Self.commonPrefixLength(Array(history.suffix(Self.earlyAgreement))), Self.earlyWords))
        }
        // Extend only: a confirmed word is never retracted on screen; the final corrects it.
        if agreed > committed.count { committed += words[committed.count..<agreed] }
        // Refresh confirmed words' punctuation/casing from the newest pass when it still agrees.
        if words.count >= committed.count,
           zip(words, committed).allSatisfy({ Self.normalise($0) == Self.normalise($1) }) {
            committed = Array(words.prefix(committed.count))
        }

        guard let onset, audioSeconds >= onset + Self.gateAfterOnset, !committed.isEmpty else { return .hold }
        let stable = committed.joined(separator: " ")
        let volatile = words.dropFirst(committed.count).joined(separator: " ")
        if let lastShown, lastShown == (stable, volatile) { return .hold }
        lastShown = (stable, volatile)
        return .show(PartialTranscript(stable: stable, volatile: volatile, audioSeconds: audioSeconds))
    }

    static func isFillerOnly(_ words: [String]) -> Bool {
        words.allSatisfy { fillers.contains(normalise($0)) }
    }

    /// Lowercased, letters/digits/apostrophes only: "Mm-hmm." == "mmhmm", "world," == "world.".
    static func normalise(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" })
    }

    private static func commonPrefixLength(_ hypotheses: [[String]]) -> Int {
        guard let shortest = hypotheses.map(\.count).min() else { return 0 }
        for i in 0..<shortest {
            let word = normalise(hypotheses[0][i])
            if hypotheses.dropFirst().contains(where: { normalise($0[i]) != word }) { return i }
        }
        return shortest
    }
}
