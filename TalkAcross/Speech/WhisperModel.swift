import Foundation

nonisolated enum WhisperModel: String, CaseIterable, Sendable {
    case base, small, largeTurbo

    var title: String {
        switch self {
        case .base: "Base"
        case .small: "Small"
        case .largeTurbo: "Large Turbo"
        }
    }

    var downloadSize: String {
        switch self {
        case .base: String(localized: "model.base.download_size")
        case .small: String(localized: "model.small.download_size")
        case .largeTurbo: String(localized: "model.large_turbo.download_size")
        }
    }

    @MainActor static var preferred: Self {
        get {
            UserDefaults.standard.string(forKey: "preferredWhisperModel").flatMap(Self.init(rawValue:)) ?? .small
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preferredWhisperModel")
        }
    }
}
