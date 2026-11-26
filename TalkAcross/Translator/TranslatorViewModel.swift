import Foundation
import Observation
import Speech
import Translation

@MainActor
@Observable
final class TranslatorViewModel {
    enum Phase {
        case idle, preparing, recording, recognizing, translating, speaking
    }

    private(set) var direction: TranslationDirection = .mandarinToJapanese
    private(set) var chineseSpeechInput = ChineseSpeechInput.preferred
    private(set) var sourceText = ""
    private(set) var translatedText = ""
    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?
    private(set) var canRetryTranslation = false
    private(set) var needsSystemSettings = false
    private(set) var needsAppSettings = false
    private(set) var engineNotice: String?
    private(set) var missingVoiceResources: [VoiceResource] = []
    private(set) var voiceResourceAlert: [VoiceResource]?

    private let recorder = AudioRecorder()
    private let appleSpeech = AppleSpeechRecognizer()
    private let whisperModels = WhisperKitModelStore.shared
    private let shanghaineseModels = ShanghaineseModelStore.shared
    private let translation = TranslationService()
    private let player = SpeechPlayer()
    @ObservationIgnored private var roundTask: Task<Void, Never>?
    @ObservationIgnored private var roundID = UUID()
    @ObservationIgnored private var recordingStarted: ContinuousClock.Instant?
    private var microphoneHeld = false

    var isBusy: Bool { phase != .idle }
    var isHoldingMicrophone: Bool { microphoneHeld && (phase == .preparing || phase == .recording) }

    func swapDirection() {
        guard !isBusy else { return }
        direction = direction.reversed
        missingVoiceResources = []
        clearDisplayedRound()
    }

    func selectChineseSpeechInput(_ input: ChineseSpeechInput) {
        guard !isBusy, direction.source == .mandarin, chineseSpeechInput != input else { return }
        chineseSpeechInput = input
        ChineseSpeechInput.preferred = input
        missingVoiceResources = []
        clearDisplayedRound()
    }

    private func clearDisplayedRound() {
        sourceText = ""
        translatedText = ""
        errorMessage = nil
        canRetryTranslation = false
        needsSystemSettings = false
        needsAppSettings = false
        engineNotice = nil
    }

    func beginPress() {
        guard !isBusy else { return }
        let id = beginRound(phase: .preparing)
        microphoneHeld = true
        let direction = self.direction
        let input = chineseSpeechInput
        let usesShanghainese = direction.source == .mandarin && input == .shanghainese
        // System permission alerts end the hold. Always require a new press after the alert.
        let needsNewPress = recorder.needsPermission || (usesShanghainese && ShanghaineseSpeechRecognizer.needsAuthorization)

        roundTask = Task { [weak self] in
            guard let self, isCurrent(id) else { return }
            defer { finishTask(id) }

            do {
                let allowed = await recorder.requestPermission()
                guard isCurrent(id) else { return }
                guard allowed else {
                    needsSystemSettings = true
                    errorMessage = String(localized: "请在系统设置中允许访问麦克风。")
                    phase = .idle
                    return
                }
                if usesShanghainese {
                    let authorized = await ShanghaineseSpeechRecognizer.requestAuthorizationIfNeeded()
                    guard isCurrent(id) else { return }
                    guard authorized else { throw SpeechRecognitionIssue.speechPermissionDenied }
                }

                let readiness = await voiceReadiness(for: direction, input: input)
                guard isCurrent(id) else { return }
                missingVoiceResources = readiness.missingResources
                guard readiness.missingResources.isEmpty else {
                    voiceResourceAlert = readiness.missingResources
                    return
                }
                if needsNewPress {
                    errorMessage = String(localized: "已获得权限，请重新按住说话。")
                    return
                }
                guard microphoneHeld else { return }

                let recognizer = try await prepareRecognizer(for: readiness.input)
                guard isCurrent(id), microphoneHeld else { return }
                let audio = try recorder.start()
                recordingStarted = .now
                phase = .recording
                let text = try await recognizer.transcribe(audio, language: direction.source) { [weak self] partial in
                    await self?.acceptPartial(partial, for: id)
                }
                guard isCurrent(id) else { return }
                recorder.stop()
                let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !finalText.isEmpty else { throw SpeechRecognitionIssue.noTranscript }
                await translate(finalText, direction: direction, input: input, for: id)
            } catch {
                guard isCurrent(id) else { return }
                recorder.stop()
                sourceText = ""
                errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "识别失败，请重试。")
                switch error as? SpeechRecognitionIssue {
                case .speechPermissionDenied:
                    needsSystemSettings = true
                case .appleUnavailable, .appleAssetsMissing, .fallbackModelMissing, .whisperModelMissing:
                    needsAppSettings = true
                default:
                    break
                }
                if error is ShanghaineseNormalizationIssue {
                    needsAppSettings = true
                }
                phase = .idle
            }
        }
    }

    func dismissVoiceResourceAlert() {
        voiceResourceAlert = nil
    }

    func refreshVoiceReadiness() async {
        guard !isBusy else { return }
        let id = roundID
        let direction = self.direction
        let input = chineseSpeechInput
        let readiness = await voiceReadiness(for: direction, input: input)
        guard isCurrent(id), !isBusy, direction == self.direction, input == chineseSpeechInput else { return }
        missingVoiceResources = readiness.missingResources
    }

    func endPress() {
        microphoneHeld = false
        switch phase {
        case .recording:
            guard let recordingStarted, recordingStarted.duration(to: .now) >= .milliseconds(500) else {
                cancel()
                errorMessage = SpeechRecognitionIssue.noTranscript.errorDescription
                return
            }
            phase = .recognizing
            recorder.stop()
        default:
            break
        }
    }

    #if DEBUG
    func translateExample() {
        let sample = switch (direction.source, chineseSpeechInput) {
        case (.mandarin, .shanghainese): "侬晓得火车站勒浪啥地方伐？"
        case (.mandarin, .mandarin): "请问，火车站在哪里？"
        case (.japanese, _): "駅はどこですか？"
        }
        translateText(sample)
    }
    #endif

    func retryTranslation() {
        guard canRetryTranslation else { return }
        translateText(sourceText)
    }

    func replay() {
        guard !isBusy, !translatedText.isEmpty else { return }
        playTranslation()
    }

    func cancel() {
        let wasCapturing = phase == .preparing || phase == .recording || phase == .recognizing
        roundID = UUID()
        roundTask?.cancel()
        roundTask = nil
        recorder.stop()
        microphoneHeld = false
        recordingStarted = nil
        player.stop()
        if wasCapturing {
            sourceText = ""
        }
        phase = .idle
    }

    func translateText(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !text.isEmpty else { return }
        let id = beginRound(phase: .translating)
        let direction = self.direction
        let speechInput = chineseSpeechInput
        roundTask = Task { [weak self] in
            guard let self else { return }
            defer { finishTask(id) }
            guard isCurrent(id) else { return }
            await translate(text, direction: direction, input: speechInput, for: id)
        }
    }

    private func translate(
        _ text: String, direction: TranslationDirection, input: ChineseSpeechInput, for id: UUID
    ) async {
        sourceText = text
        phase = .translating
        do {
            let standardText = if direction.source == .mandarin, input == .shanghainese {
                try await shanghaineseModels.normalize(text)
            } else {
                text
            }
            guard isCurrent(id) else { return }
            let response = try await translation.translate(standardText, direction: direction)
            guard isCurrent(id) else { return }
            translatedText = response
            phase = .idle
            if SpeechPlayer.isVoiceAvailable(for: direction.target) {
                playTranslation()
            }
        } catch {
            guard isCurrent(id) else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "翻译失败，请重试。")
            switch error {
            case ShanghaineseNormalizationIssue.modelMissing, ShanghaineseNormalizationIssue.invalidPack,
                 TranslationIssue.resourcesNeeded:
                needsAppSettings = true
            default:
                break
            }
            canRetryTranslation = true
            phase = .idle
        }
    }

    private func beginRound(phase: Phase) -> UUID {
        clearDisplayedRound()
        recordingStarted = nil
        self.phase = phase
        roundID = UUID()
        return roundID
    }

    private func voiceReadiness(for direction: TranslationDirection, input: ChineseSpeechInput) async -> VoiceReadiness {
        let engine = SpeechEngine.preferred
        let model = WhisperModel.preferred
        let voiceInput: VoiceInput
        let recognitionReady: Bool
        if direction.source == .mandarin, input == .shanghainese {
            voiceInput = .shanghainese
            recognitionReady = await shanghaineseModels.status == .ready
        } else {
            let appleStatus = engine == .apple ? await appleSpeech.availability(for: direction.source) : .unsupported
            if appleStatus == .unsupported {
                voiceInput = .whisper(model)
                recognitionReady = await whisperModels.status(for: model) == .ready
            } else {
                voiceInput = .apple
                recognitionReady = appleStatus == .installed
            }
        }
        return VoiceReadiness(
            direction: direction, input: voiceInput,
            translationReady: await translation.availability(for: direction) == .installed,
            recognitionReady: recognitionReady, voiceReady: SpeechPlayer.isVoiceAvailable(for: direction.target)
        )
    }

    private func prepareRecognizer(for input: VoiceInput) async throws -> any SpeechRecognizing {
        switch input {
        case .apple:
            return appleSpeech
        case .shanghainese:
            return try await ShanghaineseSpeechRecognizer.prepare()
        case .whisper(let model):
            let status = await whisperModels.recognitionStatus(for: model)
            try Task.checkCancellation()
            switch status {
            case .missing: throw SpeechRecognitionIssue.whisperModelMissing
            case .preparing: throw SpeechRecognitionIssue.whisperBusy
            case .ready: break
            }
            if SpeechEngine.preferred == .apple {
                engineNotice = String(localized: "Apple 原生识别不可用，已切换到 WhisperKit。")
            }
            return WhisperKitRecognizer(model: model)
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        id == roundID && !Task.isCancelled
    }

    private func finishTask(_ id: UUID) {
        guard id == roundID else { return }
        roundTask = nil
        recordingStarted = nil
        if phase == .preparing {
            microphoneHeld = false
            phase = .idle
        }
    }

    private func acceptPartial(_ text: String, for id: UUID) {
        guard isCurrent(id), phase == .recording || phase == .recognizing else { return }
        sourceText = text
    }

    private func playTranslation() {
        errorMessage = nil
        phase = .speaking
        do {
            try player.play(translatedText, language: direction.target) { [weak self] in
                self?.phase = .idle
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "朗读失败。")
            phase = .idle
        }
    }
}
