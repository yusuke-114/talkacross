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
        case .appleUnavailable: String(localized: "此设备暂不支持当前语言的 Apple 原生识别。")
        case .appleAssetsMissing: String(localized: "请在设置中下载当前语言的识别资源。")
        case .noTranscript: String(localized: "没有听清，请按住说话。")
        case .whisperModelMissing: String(localized: "请联网后在设置中下载 WhisperKit 模型。")
        case .whisperBusy: String(localized: "WhisperKit 正在处理，请稍后重试。")
        case .fallbackModelMissing: String(localized: "当前语言的 Apple 原生识别不可用。请联网后在设置中下载 WhisperKit 模型。")
        case .speechPermissionDenied: String(localized: "请在系统设置中允许语音识别。")
        case .shanghaineseUnavailable: String(localized: "上海话识别暂不可用，请确认可联网后重试。")
        }
    }
}
