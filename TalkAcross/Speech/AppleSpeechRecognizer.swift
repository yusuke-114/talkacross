import AVFoundation
import Speech

nonisolated struct AppleSpeechRecognizer: SpeechRecognizing {
    func availability(for language: SpokenLanguage) async -> AssetInventory.Status {
        guard let transcriber = await transcriber(for: language) else { return .unsupported }
        return await AssetInventory.status(forModules: [transcriber])
    }

    func prepare(language: SpokenLanguage) async throws {
        guard let transcriber = await transcriber(for: language) else {
            throw SpeechRecognitionIssue.appleUnavailable
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw SpeechRecognitionIssue.appleAssetsMissing
        }
    }

    @concurrent
    func transcribe(
        _ audio: AsyncThrowingStream<CapturedAudio, Error>,
        language: SpokenLanguage,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        guard let transcriber = await transcriber(for: language) else {
            throw SpeechRecognitionIssue.appleUnavailable
        }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: break
        case .unsupported: throw SpeechRecognitionIssue.appleUnavailable
        default: throw SpeechRecognitionIssue.appleAssetsMissing
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AudioCaptureIssue.conversionFailed
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let converter = AudioSampleConverter(format: format)
        let inputs = audio.compactMap { chunk in
            try converter.convert(chunk.buffer).map { AnalyzerInput(buffer: $0) }
        }

        return try await withTaskCancellationHandler {
            try await analyzer.prepareToAnalyze(in: format)
            async let transcript = collect(transcriber.results, onPartial: onPartial)
            do {
                if let lastSample = try await analyzer.analyzeSequence(inputs) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await transcript
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func transcriber(for language: SpokenLanguage) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.speechIdentifier))
        else { return nil }
        return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    private func collect(
        _ results: SpeechTranscriber.Results,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        var finalized = ""
        for try await result in results {
            let text = String(result.text.characters)
            if result.isFinal {
                finalized += text
                await onPartial(finalized)
            } else {
                await onPartial(finalized + text)
            }
        }
        return finalized
    }
}
