// CoreAudio reads for the input picker and the transport-based sleep policy (SPEC §5 step 2).
import CoreAudio
import SottoCore

public enum AudioDevices {
    public static func defaultInputID() -> AudioDeviceID? {
        let id: AudioDeviceID? = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// Every device with at least one input stream, in CoreAudio's order.
    public static func inputs() -> [(id: AudioDeviceID, device: AudioInputDevice)] {
        allDeviceIDs().compactMap { id in
            guard hasInput(id), let device = describe(id) else { return nil }
            return (id, device)
        }
    }

    public static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid: CFString = read(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name: CFString? = read(id, kAudioObjectPropertyName)
        let transport: UInt32 = read(id, kAudioDevicePropertyTransportType) ?? 0
        let rate: Float64 = read(id, kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeInput) ?? 0
        return AudioInputDevice(uid: uid as String, name: (name as String?) ?? "", transport: Self.transport(transport), sampleRate: rate)
    }

    /// Virtual (Teams/Zoom/Krisp drivers) and aggregate devices: never a stand-in microphone.
    public static func isVirtual(_ id: AudioDeviceID) -> Bool {
        let raw: UInt32 = read(id, kAudioDevicePropertyTransportType) ?? 0
        return [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate].contains(raw)
    }

    public static func transport(_ raw: UInt32) -> AudioTransport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        default: .other
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(selector: kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(selector: selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.move()
    }
}

/// Calls `onChange` on the main queue when the default input or the device list changes.
@MainActor
public final class AudioDeviceMonitor {
    private let blocks: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]

    public init(onChange: @escaping @MainActor () -> Void) {
        let block = Self.makeBlock(onChange)
        blocks = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices].map {
            (AudioObjectPropertyAddress(selector: $0), block)
        }
        for (address, block) in blocks {
            var address = address
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    // Built outside the @MainActor init, like the audio tap (CLAUDE.md); runs on .main as registered.
    private nonisolated static func makeBlock(_ onChange: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in MainActor.assumeIsolated { onChange() } }
    }

    // Lives for the process; no deinit removal needed (removal must be on the same queue anyway).
}

extension AudioObjectPropertyAddress {
    init(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
