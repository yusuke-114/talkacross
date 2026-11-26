import Foundation
import Translation

struct TranslationService {
    func availability(for direction: TranslationDirection) async -> LanguageAvailability.Status {
        return await LanguageAvailability().status(
            from: Locale.Language(identifier: direction.source.translationIdentifier),
            to: Locale.Language(identifier: direction.target.translationIdentifier)
        )
    }

    func configuration(for direction: TranslationDirection) -> TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: Locale.Language(identifier: direction.source.translationIdentifier),
            target: Locale.Language(identifier: direction.target.translationIdentifier)
        )
    }

    func translate(_ text: String, direction: TranslationDirection) async throws -> String {
        switch await availability(for: direction) {
        case .installed:
            let session = TranslationSession(
                installedSource: Locale.Language(identifier: direction.source.translationIdentifier),
                target: Locale.Language(identifier: direction.target.translationIdentifier)
            )
            return try await session.translate(text).targetText
        case .supported:
            throw TranslationIssue.resourcesNeeded
        case .unsupported:
            throw TranslationIssue.unavailable
        @unknown default:
            throw TranslationIssue.unavailable
        }
    }
}

enum TranslationIssue: LocalizedError {
    case resourcesNeeded
    case unavailable

    var errorDescription: String? {
        switch self {
        case .resourcesNeeded: String(localized: "请在设置中下载翻译语言。")
        case .unavailable: String(localized: "这台设备暂时无法使用此翻译方向。")
        }
    }
}
