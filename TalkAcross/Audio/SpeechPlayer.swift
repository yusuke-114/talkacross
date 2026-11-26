import AVFoundation

@MainActor
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var completion: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    static func isVoiceAvailable(for language: SpokenLanguage) -> Bool {
        AVSpeechSynthesisVoice(language: language.speechIdentifier) != nil
    }

    func play(_ text: String, language: SpokenLanguage, completion: @escaping () -> Void) throws {
        guard let voice = AVSpeechSynthesisVoice(language: language.speechIdentifier) else {
            throw PlaybackIssue.voiceUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        activeUtterance = utterance
        self.completion = completion
        synthesizer.speak(utterance)
    }

    func stop() {
        guard let activeUtterance else { return }
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
        finish(ObjectIdentifier(activeUtterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in finish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in finish(id) }
    }

    private func finish(_ id: ObjectIdentifier) {
        guard let activeUtterance, ObjectIdentifier(activeUtterance) == id else { return }
        self.activeUtterance = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let completion = self.completion
        self.completion = nil
        completion?()
    }
}

private enum PlaybackIssue: LocalizedError {
    case voiceUnavailable

    var errorDescription: String? {
        String(localized: "error.playback.voice_unavailable")
    }
}
