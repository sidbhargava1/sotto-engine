// Replays recorded Parakeet partial hypotheses through PartialStabilizer (spikes/stream format:
// "### <clip> batch: <text>" then "<seconds>s <ms> ... | <hypothesis>" per tick).
import Foundation
import SottoCore

public struct RecordedClip: Sendable {
    public let name: String
    public let onset: Double
    public let batch: String
    public var ticks: [(seconds: Double, text: String)]

    /// Clips named in `onsets`, in file order; others are skipped.
    public static func parse(_ text: String, onsets: [String: Double]) -> [RecordedClip] {
        var clips: [RecordedClip] = []
        var skipping = true  // until a wanted clip's header; an unwanted clip's ticks are dropped
        for line in text.split(separator: "\n") {
            if line.hasPrefix("### ") {
                skipping = true
                guard let range = line.range(of: " batch: ") else { continue }
                let name = String(line.dropFirst(4)[..<range.lowerBound])
                guard let onset = onsets[name] else { continue }
                skipping = false
                clips.append(RecordedClip(name: name, onset: onset, batch: String(line[range.upperBound...]), ticks: []))
            } else if !skipping, let bar = line.range(of: " | "), let s = line.split(separator: "s ").first.flatMap({ Double($0) }) {
                clips[clips.count - 1].ticks.append((s, String(line[bar.upperBound...])))
            }
        }
        return clips
    }

    /// What a fresh stabilizer shows over this clip's ticks, up to its stop.
    public func replay() -> [PartialTranscript] {
        var stabilizer = PartialStabilizer()
        var shown: [PartialTranscript] = []
        for tick in ticks {
            switch stabilizer.ingest(tick.text, audioSeconds: tick.seconds, onset: onset) {
            case .show(let p): shown.append(p)
            case .hold: continue
            case .stop: return shown
            }
        }
        return shown
    }
}
