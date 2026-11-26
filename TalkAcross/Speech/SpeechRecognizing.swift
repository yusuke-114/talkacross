import Foundation

nonisolated protocol SpeechRecognizing: Sendable {
    func transcribe(
        _ audio: AsyncThrowingStream<CapturedAudio, Error>,
        language: SpokenLanguage,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String
}

nonisolated enum SpeechRecognitionIssue: LocalizedError {
    case appleUnavailable
    case appleAssetsMissing
    case noTranscript
    case whisperModelMissing
    case whisperBusy
    case fallbackModelMissing
    case speechPermissionDenied
    case shanghaineseUnavailable

    var errorDescription: String? {
        switch self {
        case .appleUnavailable: String(localized: "error.speech.apple_unavailable")
        case .appleAssetsMissing: String(localized: "error.speech.apple_assets_missing")
        case .noTranscript: String(localized: "error.speech.no_transcript")
        case .whisperModelMissing: String(localized: "error.speech.whisper_model_missing")
        case .whisperBusy: String(localized: "error.speech.whisper_busy")
        case .fallbackModelMissing: String(localized: "error.speech.fallback_model_missing")
        case .speechPermissionDenied: String(localized: "error.speech.permission_denied")
        case .shanghaineseUnavailable: String(localized: "error.speech.shanghainese_unavailable")
        }
    }
}
