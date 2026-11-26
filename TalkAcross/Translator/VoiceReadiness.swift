import Foundation

enum VoiceResource: Hashable {
    case translation(TranslationDirection)
    case appleSpeech(SpokenLanguage)
    case whisperModel
    case shanghainesePack
    case voice(SpokenLanguage)

    var title: String {
        switch self {
        case .translation(let direction):
            String(
                localized: "voice_setup.resource.translation",
                defaultValue: "\(direction.source.title) → \(direction.target.title) translation resources"
            )
        case .appleSpeech(let language):
            String(localized: "voice_setup.resource.speech_recognition", defaultValue: "\(language.title) speech recognition resources")
        case .whisperModel:
            String(localized: "voice_setup.resource.whisper_model")
        case .shanghainesePack:
            String(localized: "settings.shanghainese_pack")
        case .voice(let language):
            String(localized: "voice_setup.resource.voice", defaultValue: "\(language.title) read-aloud voice")
        }
    }
}

enum VoiceInput {
    case apple
    case whisper(WhisperModel)
    case shanghainese

    func resource(for language: SpokenLanguage) -> VoiceResource {
        switch self {
        case .apple: .appleSpeech(language)
        case .whisper: .whisperModel
        case .shanghainese: .shanghainesePack
        }
    }
}

struct VoiceReadiness {
    let input: VoiceInput
    let missingResources: [VoiceResource]

    init(
        direction: TranslationDirection, input: VoiceInput,
        translationReady: Bool, recognitionReady: Bool, voiceReady: Bool
    ) {
        self.input = input
        var missing: [VoiceResource] = []
        if !translationReady {
            missing.append(.translation(direction))
        }
        if !recognitionReady {
            missing.append(input.resource(for: direction.source))
        }
        if !voiceReady {
            missing.append(.voice(direction.target))
        }
        missingResources = missing
    }
}
