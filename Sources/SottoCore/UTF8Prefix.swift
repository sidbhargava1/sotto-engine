import Foundation

/// A token can end mid-character; its bytes wait until the character completes.
public enum UTF8Prefix {
    /// Bytes up to the last complete UTF-8 scalar.
    public static func completeLength(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }  // control tokens render as nothing
        for back in 1...min(4, bytes.count) {
            let byte = bytes[bytes.count - back]
            guard byte & 0xC0 == 0x80 else {  // found the lead (or ASCII) byte
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return needed > back ? bytes.count - back : bytes.count
            }
        }
        return bytes.count
    }
}
