import Foundation

/// Mic level for the Listening meter (ui-spec §1.4): RMS mapped from dBFS onto 0…1.
public enum AudioLevel {
    /// Level updates per second; the meter interpolates between them.
    public static let rate: Double = 30

    public static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// -50 dBFS (room noise) is 0; conversational speech, about -20 dBFS RMS, lands near 0.8.
    public static func normalised(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db + 50) / 37.5, 0), 1)
    }
}
