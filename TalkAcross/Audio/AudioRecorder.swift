import AVFoundation

@MainActor
final class AudioRecorder {
    typealias Recording = AsyncThrowingStream<CapturedAudio, Error>

    private let engine = AVAudioEngine()
    private var continuation: Recording.Continuation?

    var needsPermission: Bool {
        AVAudioApplication.shared.recordPermission == .undetermined
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws -> Recording {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
        // iOS suppresses haptics during recording by default.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioCaptureIssue.microphoneUnavailable
        }

        let (recording, continuation) = Recording.makeStream()
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.capture(to: continuation))
        engine.prepare()
        do {
            try engine.start()
            return recording
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard let continuation else { return }
        self.continuation = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private nonisolated static func capture(to continuation: Recording.Continuation) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            do {
                continuation.yield(try CapturedAudio(copying: buffer))
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
