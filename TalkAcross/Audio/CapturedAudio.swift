import AVFoundation

// Tap buffers can be reused by AVAudioEngine. A chunk owns a read-only copy.
nonisolated struct CapturedAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(copying input: AVAudioPCMBuffer, offset: AVAudioFrameCount = 0, count: AVAudioFrameCount? = nil) throws {
        let count = count ?? input.frameLength
        guard count > 0, offset <= input.frameLength, count <= input.frameLength - offset,
              let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: count) else {
            throw AudioCaptureIssue.bufferUnavailable
        }
        copy.frameLength = count
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let bytes = from.mData, let output = to.mData else {
                throw AudioCaptureIssue.bufferUnavailable
            }
            let bytesPerFrame = Int(from.mDataByteSize / input.frameLength)
            output.copyMemory(from: bytes.advanced(by: Int(offset) * bytesPerFrame), byteCount: Int(count) * bytesPerFrame)
        }
        buffer = copy
    }
}

nonisolated enum AudioCaptureIssue: LocalizedError {
    case microphoneUnavailable
    case bufferUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: String(localized: "麦克风暂时不可用。")
        case .bufferUnavailable, .conversionFailed: String(localized: "无法读取本轮录音，请重试。")
        }
    }
}
