import Observation
import Speech
import Translation

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var translationStatuses: [TranslationDirection: LanguageAvailability.Status] = [:]
    private(set) var downloading: TranslationDirection?
    private(set) var failedDownload: TranslationDirection?
    private(set) var downloadConfiguration: TranslationSession.Configuration?
    private(set) var speechStatuses: [SpokenLanguage: AssetInventory.Status] = [:]
    private(set) var voiceAvailability: [SpokenLanguage: Bool] = [:]
    private(set) var preparingSpeech: SpokenLanguage?
    private(set) var failedSpeech: SpokenLanguage?
    private(set) var engine = SpeechEngine.preferred
    private(set) var model = WhisperModel.preferred
    private(set) var modelStatus: WhisperKitModelStore.Status?
    private(set) var modelMessage: String?
    private(set) var shanghaineseStatus: ShanghaineseModelStore.Status?
    private(set) var shanghaineseMessage: String?
    private(set) var shanghaineseProgress: Double?
    private(set) var modelProgress: Double?

    private let translation = TranslationService()
    private let speech = AppleSpeechRecognizer()
    private let whisperModels = WhisperKitModelStore.shared
    private let shanghaineseModels = ShanghaineseModelStore.shared

    func refresh() async {
        await refreshShanghaineseStatus()
        await refreshModelStatus()
        for direction in TranslationDirection.allCases {
            let status = await translation.availability(for: direction)
            guard !Task.isCancelled else { return }
            translationStatuses[direction] = status
        }
        await refreshSpeechStatuses(for: SpokenLanguage.allCases)
        guard !Task.isCancelled else { return }
        for language in SpokenLanguage.allCases {
            voiceAvailability[language] = SpeechPlayer.isVoiceAvailable(for: language)
        }
    }

    /// True while the system reports an Apple recognition asset as downloading, possibly started by an earlier Settings page.
    var hasSpeechDownloadInProgress: Bool {
        speechStatuses.values.contains(.downloading)
    }

    func refreshSpeechStatuses(for languages: [SpokenLanguage]? = nil) async {
        let languages = languages ?? SpokenLanguage.allCases.filter { speechStatuses[$0] == .downloading }
        for language in languages {
            let status = await speech.availability(for: language)
            guard !Task.isCancelled else { return }
            speechStatuses[language] = status
        }
    }

    func refreshShanghaineseStatus() async {
        let status = await shanghaineseModels.status
        let progress = await shanghaineseModels.downloadFraction
        guard !Task.isCancelled else { return }
        shanghaineseStatus = status
        shanghaineseProgress = progress
    }

    func downloadShanghainesePack() async {
        guard shanghaineseStatus == .missing else { return }
        shanghaineseStatus = .downloading
        shanghaineseMessage = nil
        do {
            try await shanghaineseModels.download()
        } catch {
            shanghaineseMessage = String(localized: "error.shanghainese.download_failed")
        }
        await refreshShanghaineseStatus()
    }

    func removeShanghainesePack() async {
        guard shanghaineseStatus == .ready else { return }
        shanghaineseMessage = nil
        do {
            try await shanghaineseModels.remove()
        } catch {
            shanghaineseMessage = String(localized: "error.model.deletion_failed")
        }
        await refreshShanghaineseStatus()
    }

    func refreshModelStatus() async {
        let selectedModel = model
        let status = await whisperModels.status(for: selectedModel)
        let progress = await whisperModels.downloadFraction
        guard model == selectedModel, !Task.isCancelled else { return }
        modelStatus = status
        modelProgress = progress
    }

    func selectEngine(_ engine: SpeechEngine) {
        self.engine = engine
        SpeechEngine.preferred = engine
    }

    func selectModel(_ model: WhisperModel) {
        guard self.model != model else { return }
        self.model = model
        WhisperModel.preferred = model
        modelStatus = nil
        modelMessage = nil
    }

    func downloadModel() async {
        guard modelStatus == .missing else { return }
        let selectedModel = model
        modelStatus = .preparing
        modelMessage = nil
        do {
            try await whisperModels.prepare(selectedModel)
        } catch {
            guard model == selectedModel else { return }
            modelMessage = (error as? SpeechRecognitionIssue)?.errorDescription ?? String(localized: "error.model.preparation_failed")
        }
        guard model == selectedModel else { return }
        await refreshModelStatus()
    }

    func removeModel() async {
        guard modelStatus == .ready else { return }
        let selectedModel = model
        modelMessage = nil
        do {
            try await whisperModels.remove(selectedModel)
        } catch {
            guard model == selectedModel else { return }
            modelMessage = (error as? SpeechRecognitionIssue)?.errorDescription ?? String(localized: "error.model.deletion_failed")
        }
        guard model == selectedModel else { return }
        await refreshModelStatus()
    }

    func downloadSpeech(for language: SpokenLanguage) async {
        guard preparingSpeech == nil, speechStatuses[language] == .supported else { return }
        preparingSpeech = language
        failedSpeech = nil
        defer { preparingSpeech = nil }

        do {
            try await speech.prepare(language: language)
        } catch {
            failedSpeech = language
        }
        speechStatuses[language] = await speech.availability(for: language)
    }

    func requestDownload(for direction: TranslationDirection) {
        guard downloading == nil, translationStatuses[direction] == .supported else { return }
        failedDownload = nil
        downloading = direction
        downloadConfiguration = translation.configuration(for: direction)
    }

    func prepareTranslation(using session: TranslationSession) async {
        guard let direction = downloading else { return }
        defer {
            downloading = nil
            downloadConfiguration = nil
        }

        do {
            try await session.prepareTranslation()
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                failedDownload = direction
            }
        }
        await refresh()
    }
}
