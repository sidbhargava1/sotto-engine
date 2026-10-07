import AVFoundation

public enum AudioConversion {
    public static let targetRate: Double = 16_000

    public enum Failure: Error { case formatUnsupported, conversionFailed(String) }

    /// Mono Float32 at `sourceRate` -> 16kHz mono Float32 (PLAN §4: the converter stage is mandatory).
    public static func to16kMono(_ samples: [Float], sourceRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        if sourceRate == targetRate { return samples }
        guard let inFormat = monoFormat(sourceRate) else { throw Failure.formatUnsupported }
        let input = try pcmBuffer(samples, format: inFormat)
        return try floats(from: convert(input, to: monoFormat(targetRate)!))
    }

    public static func convert(_ input: AVAudioPCMBuffer, to outFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: input.format, to: outFormat) else {
            throw Failure.formatUnsupported
        }
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw Failure.formatUnsupported
        }
        // The input block runs synchronously inside convert(); nothing escapes this call.
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw Failure.conversionFailed(error?.localizedDescription ?? "unknown") }
        return output
    }

    public static func monoFormat(_ rate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
    }

    public static func pcmBuffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw Failure.formatUnsupported }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    public static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Averages channels so a stereo interface doesn't lose one side.
    public static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: frames)) }
        var out = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let ch = data[c]
            for i in 0..<frames { out[i] += ch[i] }
        }
        let scale = 1 / Float(channels)
        for i in 0..<frames { out[i] *= scale }
        return out
    }

    public static func loadFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure.formatUnsupported
        }
        try file.read(into: buffer)
        return try to16kMono(downmix(buffer), sourceRate: format.sampleRate)
    }
}

/// One long-lived converter across a stream of chunks, so filter state carries over each seam
/// (`to16kMono` makes a fresh converter per call, which would glitch every 100 ms).
public final class StreamingResampler {
    public let sourceRate: Double
    private let converter: AVAudioConverter?  // nil: already 16 kHz
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat

    public init(sourceRate: Double) throws {
        guard let inFormat = AudioConversion.monoFormat(sourceRate),
              let outFormat = AudioConversion.monoFormat(AudioConversion.targetRate)
        else { throw AudioConversion.Failure.formatUnsupported }
        self.sourceRate = sourceRate
        self.inFormat = inFormat
        self.outFormat = outFormat
        if sourceRate == AudioConversion.targetRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw AudioConversion.Failure.formatUnsupported }
            self.converter = converter
        }
    }

    /// Feeds one chunk; the converter keeps its tail for the next call (`.noDataNow`).
    public func process(_ samples: [Float]) throws -> [Float] {
        guard let converter else { return samples }
        guard !samples.isEmpty else { return [] }
        return try run(converter, input: AudioConversion.pcmBuffer(samples, format: inFormat), frames: samples.count, end: false)
    }

    /// Drains the converter's tail; the resampler is spent afterwards.
    public func flush() throws -> [Float] {
        guard let converter else { return [] }
        return try run(converter, input: nil, frames: 0, end: true)
    }

    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, frames: Int, end: Bool) throws -> [Float] {
        let capacity = AVAudioFrameCount((Double(frames) * AudioConversion.targetRate / sourceRate).rounded(.up)) + 1024
        // The input block runs synchronously inside convert(); nothing escapes this call.
        nonisolated(unsafe) var input = input
        var out: [Float] = []
        while true { // the converter batches internally; a full output buffer means more is waiting
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { throw AudioConversion.Failure.formatUnsupported }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if let buffer = input {
                    input = nil
                    outStatus.pointee = .haveData
                    return buffer
                }
                outStatus.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw AudioConversion.Failure.conversionFailed(error?.localizedDescription ?? "unknown") }
            out += AudioConversion.floats(from: output)
            guard status == .haveData, output.frameLength == output.frameCapacity else { return out }
        }
    }
}
