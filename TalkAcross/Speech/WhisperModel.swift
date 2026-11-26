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
        case .base: String(localized: "约 147 MB")
        case .small: String(localized: "约 486 MB")
        case .largeTurbo: String(localized: "约 646 MB")
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
