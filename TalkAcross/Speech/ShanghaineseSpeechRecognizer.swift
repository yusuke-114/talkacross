import Foundation
import Speech

// The recognizer is only read after preparation, so the wrapper can cross isolation domains.
nonisolated struct ShanghaineseSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    private static let locale = Locale(identifier: "wuu-CN")

    private let recognizer: SFSpeechRecognizer

    @MainActor static var needsAuthorization: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    @MainActor static func requestAuthorizationIfNeeded() async -> Bool {
        var authorization = SFSpeechRecognizer.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await requestAuthorization()
        }
        return authorization == .authorized
    }

    @MainActor static func prepare() async throws -> Self {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.locale.language.languageCode?.identifier == "wuu" else {
            throw SpeechRecognitionIssue.shanghaineseUnavailable
        }
        guard await requestAuthorizationIfNeeded() else {
            throw SpeechRecognitionIssue.speechPermissionDenied
        }
        guard recognizer.isAvailable else {
            throw SpeechRecognitionIssue.shanghaineseUnavailable
        }
        return Self(recognizer: recognizer)
    }

    @concurrent
    func transcribe(
        _ audio: AsyncThrowingStream<CapturedAudio, Error>,
        language _: SpokenLanguage,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        try Task.checkCancellation()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let (results, continuation) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let recognition = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(to: continuation))
        let input = Task {
            do {
                for try await chunk in audio {
                    try Task.checkCancellation()
                    request.append(chunk.buffer)
                }
                try Task.checkCancellation()
                request.endAudio()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        defer {
            input.cancel()
            recognition.cancel()
        }

        var text = ""
        do {
            for try await result in results {
                try Task.checkCancellation()
                text = result
                await onPartial(result)
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || error is AudioCaptureIssue { throw error }
            // Keep what was heard before the recognizer stopped.
            if !text.isEmpty { return text }
            // An empty transcript lets the caller report that nothing was heard.
            if Self.isNoSpeech(error) { return "" }
            throw SpeechRecognitionIssue.shanghaineseUnavailable
        }
        try Task.checkCancellation()
        return text
    }

    private static func isNoSpeech(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func resultHandler(
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result {
                continuation.yield(result.bestTranscription.formattedString)
                if result.isFinal {
                    continuation.finish()
                    return
                }
            }
            if let error {
                continuation.finish(throwing: error)
            }
        }
    }
}
