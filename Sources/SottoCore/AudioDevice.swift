import Foundation

/// How the input device reaches the Mac. Bluetooth matters: opening its mic forces the HFP
/// route switch, which costs hundreds of ms to seconds (SPEC §5 step 2).
public enum AudioTransport: String, Sendable, Equatable {
    case builtIn, usb, bluetooth, other
}

public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public var uid: String
    public var name: String
    public var transport: AudioTransport
    public var sampleRate: Double
    public var id: String { uid }

    public init(uid: String, name: String, transport: AudioTransport, sampleRate: Double) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.sampleRate = sampleRate
    }
}
