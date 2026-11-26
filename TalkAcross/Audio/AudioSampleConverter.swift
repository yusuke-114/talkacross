import AVFoundation

// The recognition pipeline calls convert serially for a single recording.
nonisolated final class AudioSampleConverter: @unchecked Sendable {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        guard input.format != format else { return input }

        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
            converter?.primeMethod = .none
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 8
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioCaptureIssue.conversionFailed
        }

        var error: NSError?
        var nextFrame: AVAudioFrameCount = 0
        var failedToCopy = false
        let result = converter.convert(to: output, error: &error) { requested, status in
            let frames = min(requested, input.frameLength - nextFrame)
            guard frames > 0 else {
                status.pointee = .noDataNow
                return nil
            }
            let offset = nextFrame
            nextFrame += frames
            status.pointee = .haveData
            if frames == input.frameLength { return input }
            guard let slice = try? CapturedAudio(copying: input, offset: offset, count: frames) else {
                failedToCopy = true
                status.pointee = .noDataNow
                return nil
            }
            return slice.buffer
        }
        guard result != .error, !failedToCopy else {
            throw AudioCaptureIssue.conversionFailed
        }
        return output.frameLength == 0 ? nil : output
    }
}
