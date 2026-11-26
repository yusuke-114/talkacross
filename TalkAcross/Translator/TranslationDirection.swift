import Foundation

nonisolated enum ChineseSpeechInput: String, Sendable {
    case mandarin, shanghainese

    var title: String {
        switch self {
        case .mandarin: String(localized: "普通话")
        case .shanghainese: String(localized: "上海话")
        }
    }

    @MainActor static var preferred: Self {
        get {
            UserDefaults.standard.string(forKey: "preferredChineseSpeechInput").flatMap(Self.init(rawValue:)) ?? .mandarin
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preferredChineseSpeechInput")
        }
    }
}

nonisolated enum SpokenLanguage: CaseIterable, Sendable {
    case mandarin
    case japanese

    var title: String {
        switch self {
        case .mandarin: String(localized: "中文")
        case .japanese: String(localized: "日本語")
        }
    }

    var speechIdentifier: String {
        switch self {
        case .mandarin: "zh-CN"
        case .japanese: "ja-JP"
        }
    }

    var translationIdentifier: String {
        switch self {
        case .mandarin: "zh-Hans"
        case .japanese: "ja"
        }
    }
}

nonisolated enum TranslationDirection: CaseIterable, Sendable {
    case mandarinToJapanese
    case japaneseToMandarin

    var source: SpokenLanguage {
        switch self {
        case .mandarinToJapanese: .mandarin
        case .japaneseToMandarin: .japanese
        }
    }

    var target: SpokenLanguage {
        reversed.source
    }

    var reversed: Self {
        switch self {
        case .mandarinToJapanese: .japaneseToMandarin
        case .japaneseToMandarin: .mandarinToJapanese
        }
    }
}
