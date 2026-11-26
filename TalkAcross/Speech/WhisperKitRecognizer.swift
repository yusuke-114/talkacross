import AVFoundation
@preconcurrency import WhisperKit

nonisolated struct WhisperKitRecognizer: SpeechRecognizing {
    let model: WhisperModel

    func transcribe(
        _ audio: AsyncThrowingStream<CapturedAudio, Error>,
        language: SpokenLanguage,
        onPartial _: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try await WhisperKitModelStore.shared.transcribe(audio, language: language, model: model)
    }
}

actor WhisperKitModelStore {
    enum Status: Sendable {
        case missing, preparing, ready
    }

    static let shared = WhisperKitModelStore()

    private let directory: URL
    private var loadedModel: (model: WhisperModel, recognizer: WhisperKit)?
    private var preparingModel: WhisperModel?
    private var isTranscribing = false
    private var isDownloadingFiles = false
    private let downloadProgress = DownloadProgress()

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "TalkAcross/WhisperKit")) {
        self.directory = directory
    }

    func status(for model: WhisperModel) -> Status {
        if preparingModel == model { return .preparing }
        return hasLocalFiles(for: model) ? .ready : .missing
    }

    /// Fraction of the model files downloaded, or nil outside the download stage.
    var downloadFraction: Double? { isDownloadingFiles ? downloadProgress.fraction : nil }

    func recognitionStatus(for model: WhisperModel) -> Status {
        if preparingModel != nil || isTranscribing { return .preparing }
        return status(for: model)
    }

    func prepare(_ model: WhisperModel) async throws {
        guard preparingModel == nil, !isTranscribing else { throw SpeechRecognitionIssue.whisperBusy }
        guard !hasLocalFiles(for: model) else { return }

        preparingModel = model
        defer { preparingModel = nil }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)

        downloadProgress.update(0)
        isDownloadingFiles = true
        defer { isDownloadingFiles = false }
        let folder = try await WhisperKit.download(
            variant: model.variant, downloadBase: directory,
            progressCallback: Self.report(to: downloadProgress)
        )
        isDownloadingFiles = false
        _ = try await ModelUtilities.loadTokenizer(for: model.tokenizerVariant, tokenizerFolder: directory)
        try Task.checkCancellation()
        _ = try await loadModel(model, from: folder)
        try Task.checkCancellation()
        try Data().write(to: readyFile(for: model), options: .atomic)
    }

    private nonisolated static func report(to progress: DownloadProgress) -> @Sendable (Progress) -> Void {
        { progress.update($0.fractionCompleted) }
    }

    func remove(_ model: WhisperModel) throws {
        guard preparingModel == nil, !isTranscribing else { throw SpeechRecognitionIssue.whisperBusy }
        if loadedModel?.model == model {
            loadedModel = nil
        }
        let downloadCache = modelRepository.appending(path: ".cache/huggingface/download").appending(path: model.variant)
        for file in [readyFile(for: model), modelFolder(for: model), tokenizerFolder(for: model), downloadCache] {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    func transcribe(
        _ audio: AsyncThrowingStream<CapturedAudio, Error>,
        language: SpokenLanguage,
        model: WhisperModel
    ) async throws -> String {
        guard preparingModel == nil, !isTranscribing else { throw SpeechRecognitionIssue.whisperBusy }
        guard hasLocalFiles(for: model) else { throw SpeechRecognitionIssue.whisperModelMissing }
        isTranscribing = true
        defer { isTranscribing = false }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw AudioCaptureIssue.conversionFailed
        }
        // Load the model while the user is still speaking. Every exit waits for the load,
        // so isTranscribing keeps a second load from starting.
        let folder = modelFolder(for: model)
        let loading = Task { _ = try await loadModel(model, from: folder) }
        let samples: [Float]
        do {
            samples = try await collectSamples(from: audio, format: format)
        } catch {
            _ = try? await loading.value
            throw error
        }
        guard !samples.isEmpty else {
            _ = try? await loading.value
            return ""
        }

        try await loading.value
        // Returns the instance cached by the load above.
        let recognizer = try await loadModel(model, from: folder)
        try Task.checkCancellation()

        let options = DecodingOptions(
            task: .transcribe,
            language: language == .mandarin ? "zh" : "ja",
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )
        let results = try await recognizer.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined()
        if language == .mandarin {
            return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        }
        return text
    }

    private func collectSamples(
        from audio: AsyncThrowingStream<CapturedAudio, Error>, format: AVAudioFormat
    ) async throws -> [Float] {
        let converter = AudioSampleConverter(format: format)
        var samples: [Float] = []
        for try await chunk in audio {
            try Task.checkCancellation()
            if let buffer = try converter.convert(chunk.buffer), let channel = buffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
        }
        try Task.checkCancellation()
        return samples
    }

    private var modelRepository: URL { directory.appending(path: "models/argmaxinc/whisperkit-coreml") }

    private func readyFile(for model: WhisperModel) -> URL {
        directory.appending(path: "\(model.rawValue).ready")
    }

    private func modelFolder(for model: WhisperModel) -> URL {
        modelRepository.appending(path: model.variant)
    }

    private func tokenizerFolder(for model: WhisperModel) -> URL {
        directory.appending(path: "models/openai").appending(path: model.tokenizerName)
    }

    private func hasLocalFiles(for model: WhisperModel) -> Bool {
        let modelFolder = modelFolder(for: model)
        let tokenizerFolder = tokenizerFolder(for: model)
        let modelFiles = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]
        return FileManager.default.fileExists(atPath: readyFile(for: model).path)
            && modelFiles.allSatisfy { FileManager.default.fileExists(atPath: modelFolder.appending(path: $0).path) }
            && tokenizerFiles.allSatisfy { FileManager.default.fileExists(atPath: tokenizerFolder.appending(path: $0).path) }
    }

    private func loadModel(_ model: WhisperModel, from folder: URL) async throws -> WhisperKit {
        if let loadedModel, loadedModel.model == model {
            return loadedModel.recognizer
        }
        loadedModel = nil
        let recognizer = try await WhisperKit(
            WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: tokenizerFolder(for: model), verbose: false, load: true, download: false)
        )
        loadedModel = (model, recognizer)
        return recognizer
    }
}

private extension WhisperModel {
    nonisolated var variant: String {
        switch self {
        case .base: "openai_whisper-base"
        case .small: "openai_whisper-small"
        case .largeTurbo: "openai_whisper-large-v3-v20240930_turbo_632MB"
        }
    }

    nonisolated var tokenizerVariant: ModelVariant {
        switch self {
        case .base: .base
        case .small: .small
        case .largeTurbo: .largev3
        }
    }

    nonisolated var tokenizerName: String {
        switch self {
        case .base: "whisper-base"
        case .small: "whisper-small"
        case .largeTurbo: "whisper-large-v3"
        }
    }
}
