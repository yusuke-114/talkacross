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
            String(localized: "\(direction.source.title) → \(direction.target.title) 翻译资源")
        case .appleSpeech(let language):
            String(localized: "\(language.title)语音识别资源")
        case .whisperModel:
            String(localized: "WhisperKit 识别模型")
        case .shanghainesePack:
            String(localized: "上海话转换包")
        case .voice(let language):
            String(localized: "\(language.title)朗读语音")
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
