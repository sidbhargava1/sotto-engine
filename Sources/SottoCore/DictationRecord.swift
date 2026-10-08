import Foundation

/// The `delivery` column (SPEC §15.2).
public enum DeliveryKind: String, Sendable, Equatable, CaseIterable {
    case ax
    case paste
    case unicode
    case clipboard

    init(_ strategy: InjectionStrategy) {
        switch strategy {
        case .axSelectedText: self = .ax
        case .paste: self = .paste
        case .unicodeType: self = .unicode
        }
    }
}

/// What one delivery path put in front of the user.
public struct Delivery: Sendable, Equatable {
    public var landedText: String
    public var strategy: DeliveryKind
    public var degraded: DegradedReason?
    // Landing facts for `LastLanding`; internal, since History rows don't carry them.
    var writes = 0
    var verified = false  // every write was an AX `.success`
    var start: FieldRange?  // the selection before the first write, when it was read
    var fieldCount: Int?  // set when the replace already read it
    var noWrite = false  // replace found the text unchanged: nothing landed, nothing to record
}

/// One completed utterance, handed to the `HistoryRecording` hook (shaped as SPEC §15.2's
/// `dictations` row). `id` only pairs a later "scratch that" with its record. `bundleID` is the
/// press-time app as the session saw it; the recorder decides what it stores.
public struct DictationRecord: Sendable, Equatable {
    public var id: UUID
    public var startedAt: Date
    public var heldMs: Int
    public var bundleID: String?
    public var delivery: DeliveryKind
    public var degraded: DegradedReason?
    public var backend: String
    public var rawText: String
    public var cleanText: String
    public var words: Int
    public var sttMs: Int
    public var cleanupMs: Int
    public var landedMs: Int

    public init(id: UUID = UUID(), startedAt: Date, heldMs: Int, bundleID: String?, delivery: DeliveryKind, degraded: DegradedReason?, backend: String, rawText: String, cleanText: String, sttMs: Int, cleanupMs: Int, landedMs: Int) {
        self.id = id
        self.startedAt = startedAt
        self.heldMs = max(0, heldMs)  // HI-50
        self.bundleID = bundleID
        self.delivery = delivery
        self.degraded = degraded
        self.backend = backend
        self.rawText = rawText
        self.cleanText = cleanText
        self.words = Self.wordCount(cleanText)
        self.sttMs = max(0, sttMs)
        self.cleanupMs = max(0, cleanupMs)
        self.landedMs = max(0, landedMs)
    }

    /// HI-45: whitespace-separated tokens holding at least one letter or digit, so a spaced em
    /// dash isn't a word and "don't" / "well-known" are one each.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
    }
}
