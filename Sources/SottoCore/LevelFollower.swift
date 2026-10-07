import Foundation

/// Asymmetric one-pole envelope: separate time constants for rising and falling input (0 = jump).
/// One type for both trackers that make level relative to the speaker: the onset gate's noise floor
/// (instant fall, slow rise) and the mouth's peak (instant rise, slow fall), ui-spec §1.6.
public struct LevelFollower: Sendable {
    public let rise: Double  // seconds
    public let fall: Double
    public private(set) var value: Double?

    public init(rise: Double, fall: Double) {
        self.rise = rise
        self.fall = fall
    }

    /// A noise floor: drops to any quieter window at once, creeps up through sustained sound.
    public static func floor() -> LevelFollower { LevelFollower(rise: 2, fall: 0) }
    /// A peak: jumps to the loudest syllable, lets go over a couple of seconds.
    public static func peak() -> LevelFollower { LevelFollower(rise: 0, fall: 1.5) }

    @discardableResult
    public mutating func next(_ x: Double, dt: Double) -> Double {
        guard let v = value else { value = x; return x }
        let tau = x > v ? rise : fall
        let out = tau <= 0 ? x : v + (x - v) * (1 - exp(-dt / tau))
        value = out
        return out
    }

    public mutating func reset() { value = nil }
}
