import Foundation

enum SpeechEngine: String, CaseIterable {
    case apple, whisperKit

    var title: String {
        switch self {
        case .apple: String(localized: "Apple 原生")
        case .whisperKit: "WhisperKit"
        }
    }

    static var preferred: Self {
        get {
            UserDefaults.standard.string(forKey: "preferredSpeechEngine").flatMap(Self.init(rawValue:)) ?? .apple
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preferredSpeechEngine")
        }
    }
}
