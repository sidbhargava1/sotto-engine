// The voice-command grammar: pure text in, a parsed command out. Runs on the raw transcript AFTER
// the dictionary heard-as rewrite (the only alias source) and before cleanup. Case, punctuation and
// extra spaces are ignored; the verb list is closed. "Scratch that" stays in `CommandParser`.
import Foundation

public enum CommandVerb: Sendable, Equatable {
    case open, switchTo, hide, run
}

public struct ParsedCommand: Sendable, Equatable {
    public let verb: CommandVerb
    /// Set by "open folder X" / "open link X"; nil lets the resolver choose.
    public let forcedKind: CommandTargetKind?
    /// The target phrase as heard (punctuation stripped, case kept), 1...4 words, filler removed.
    public let target: String
    public var targetWordCount: Int { target.split(separator: " ").count }
}

public enum CommandGrammar {
    /// Targets longer than this are never named in a message.
    public static let maxTargetWords = 4

    /// Initial variants only; "otto" is a real name, so it is not here.
    static let wakeVariants: [[String]] = [["sotto"], ["soto"], ["so", "to"]]
    static let leadingFiller: [[String]] = [["can", "you"], ["could", "you"], ["please"], ["hey"]]
    static let trailingFiller: [[String]] = [["for", "me"], ["please"], ["up"]]
    static let deictics: Set<String> = [
        "this", "this app", "that", "that app", "it", "the window", "this window", "that window",
        "this one", "that one",
    ]

    enum Scan: Equatable {
        case notACommand        // no verb in the table
        case noObject           // verb, nothing after it
        case deictic            // "this app", "it"
        case tooLong            // target over 4 words
        case command(ParsedCommand)
    }

    struct Word: Equatable {
        let text: String  // punctuation stripped, case kept
        let key: String   // lowercased
    }

    /// Bounds on what is examined, so a pasted wall of text costs a fixed amount of work. A real
    /// command is a few words; anything past the cap is already "too long" or not a command.
    static let maxScannedCharacters = 2_000
    static let maxScannedWords = 32
    /// A "word" longer than this is not a name anyone spoke; never echoed back in a message.
    static let maxWordLength = 64

    static func words(_ raw: String) -> [Word] {
        raw.prefix(maxScannedCharacters).split(whereSeparator: \.isWhitespace).prefix(maxScannedWords).compactMap { token in
            let text = String(String.UnicodeScalarView(
                token.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }))
            return text.isEmpty ? nil : Word(text: text, key: text.lowercased())
        }
    }

    /// Command-key entry: a leading "Sotto," is accepted and ignored.
    public static func parseCommandKey(_ transcript: String) -> ParsedCommand? {
        let w = words(transcript)
        var i = 0
        while true {
            if let n = matchLeading(w, at: i, wake: true) { i += n } else { break }
        }
        if case .command(let c) = scan(w, from: i) { return c }
        return nil
    }

    /// Dictation-key prefix entry: the wake word must be the first word, then only filler (at most
    /// two words, so the verb is within 3 words of the wake word), then a verb.
    static func scanPrefix(_ transcript: String) -> Scan {
        let w = words(transcript)
        guard let wake = wakeVariants.first(where: { matches(w, at: 0, $0) }) else { return .notACommand }
        var i = wake.count
        while let n = matchLeading(w, at: i, wake: false) { i += n }
        guard i - wake.count <= 2 else { return .notACommand }
        return scan(w, from: i)
    }

    static func matchLeading(_ w: [Word], at i: Int, wake: Bool) -> Int? {
        let options = wake ? leadingFiller + wakeVariants : leadingFiller
        return options.first(where: { matches(w, at: i, $0) })?.count
    }

    static func matches(_ w: [Word], at i: Int, _ phrase: [String]) -> Bool {
        guard i + phrase.count <= w.count else { return false }
        return phrase.indices.allSatisfy { w[i + $0].key == phrase[$0] }
    }

    static func scan(_ w: [Word], from i: Int) -> Scan {
        guard i < w.count else { return .notACommand }
        let verb: CommandVerb
        var forced: CommandTargetKind?
        var next = i
        switch w[i].key {
        case "open", "launch":
            verb = .open
            next = i + 1
            if next < w.count, w[next].key == "folder" { forced = .folder; next += 1 }
            else if next < w.count, w[next].key == "link" { forced = .link; next += 1 }
        case "switch" where matches(w, at: i, ["switch", "to"]),
             "go" where matches(w, at: i, ["go", "to"]):
            verb = .switchTo
            next = i + 2
        case "hide":
            verb = .hide
            next = i + 1
        case "run":
            verb = .run
            next = i + 1
            if next < w.count, w[next].key == "shortcut" { forced = .shortcut; next += 1 }
        default:
            return .notACommand
        }

        var target = Array(w[next...])
        while let n = trailingFiller.first(where: { f in
            target.count >= f.count && f.indices.allSatisfy { target[target.count - f.count + $0].key == f[$0] }
        })?.count {
            target.removeLast(n)
        }
        guard !target.isEmpty else { return .noObject }
        if deictics.contains(target.map(\.key).joined(separator: " ")) { return .deictic }
        guard target.count <= maxTargetWords, target.allSatisfy({ $0.text.count <= maxWordLength }) else {
            return .tooLong
        }
        return .command(ParsedCommand(
            verb: verb, forcedKind: forced, target: target.map(\.text).joined(separator: " ")))
    }
}
