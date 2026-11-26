import AVFoundation
import Combine
import SwiftUI

struct TranslatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @FocusState private var focusesTextInput: Bool
    @GestureState private var microphonePressed = false
    @State private var viewModel = TranslatorViewModel()
    @State private var showsSettings = false
    @State private var showsTextInput = false
    @State private var textDraft = ""

    private struct VoiceReadinessCheck: Equatable {
        let direction: TranslationDirection
        let input: ChineseSpeechInput
    }

    private var voiceReadinessCheck: VoiceReadinessCheck? {
        guard scenePhase == .active, !showsSettings else { return nil }
        return VoiceReadinessCheck(direction: viewModel.direction, input: viewModel.chineseSpeechInput)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    directionControl
                    if !showsTextInput, !viewModel.missingVoiceResources.isEmpty {
                        voiceSetupPrompt
                    }
                    transcript("translator.source_text", text: viewModel.sourceText)
                    transcript("translator.translated_text", text: viewModel.translatedText, canReplay: true)

                    if let notice = viewModel.engineNotice {
                        Text(notice)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !showsTextInput, let message = viewModel.errorMessage {
                        VStack(spacing: 8) {
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if viewModel.canRetryTranslation {
                                Button("common.retry", action: viewModel.retryTranslation)
                            }
                            if viewModel.needsSystemSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                                Button("common.open_system_settings") { openURL(settings) }
                            }
                            if viewModel.needsAppSettings {
                                Button("common.settings") { showsSettings = true }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !showsTextInput {
                    microphoneControl
                }
            }
            .navigationTitle("TalkAcross")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Button("translator.sample", action: viewModel.translateExample)
                        .disabled(viewModel.isBusy || showsTextInput)
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.settings", systemImage: "gearshape") {
                        showsSettings = true
                    }
                    .disabled(viewModel.isBusy)
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView(priorityResources: viewModel.missingVoiceResources)
            }
            .task(id: voiceReadinessCheck) {
                guard voiceReadinessCheck != nil else { return }
                await viewModel.refreshVoiceReadiness()
            }
            .alert(
                "voice_setup.alert_title",
                isPresented: Binding(
                    get: { viewModel.voiceResourceAlert != nil },
                    set: { if !$0 { viewModel.dismissVoiceResourceAlert() } }
                ),
                presenting: viewModel.voiceResourceAlert
            ) { _ in
                Button("voice_setup.open_settings") { showsSettings = true }
                Button("common.later", role: .cancel) { }
            } message: { resources in
                Text(resources.map(\.title).joined(separator: "\n"))
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background {
                    viewModel.cancel()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                viewModel.cancel()
            }
        }
    }

    private var voiceSetupPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("voice_setup.title")
                .font(.subheadline.weight(.semibold))
            Text(viewModel.missingVoiceResources.map(\.title).formatted(.list(type: .and)))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("voice_setup.open_settings") { showsSettings = true }
                .font(.subheadline)
                .disabled(viewModel.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .accessibilityIdentifier("voiceSetupPrompt")
    }

    private var microphoneControl: some View {
        let capturing = viewModel.isHoldingMicrophone
        let available = !viewModel.isBusy || capturing
        let recording = viewModel.phase == .recording
        let title: LocalizedStringKey = switch viewModel.phase {
        case .preparing: "common.preparing"
        case .recording: "translator.release_to_finish"
        case .recognizing: "translator.recognizing"
        case .translating: "translator.translating"
        case .speaking: "translator.speaking"
        case .idle: "translator.hold_to_speak"
        }

        return Label(title, systemImage: recording ? "waveform" : "mic.fill")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(available ? Color.white : Color.secondary)
            .background(
                available ? (recording ? Color.red : Color.accentColor) : Color(.secondarySystemFill),
                in: .capsule
            )
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($microphonePressed) { _, isPressed, _ in isPressed = true }
            )
            .onChange(of: microphonePressed) {
                if microphonePressed {
                    viewModel.beginPress()
                } else {
                    viewModel.endPress()
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: recording) { _, isRecording in
                isRecording
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("translator.microphone_accessibility_hint")
            .accessibilityAction {
                if capturing {
                    viewModel.endPress()
                } else {
                    viewModel.beginPress()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.systemGroupedBackground))
    }

    private var directionControl: some View {
        HStack(spacing: 12) {
            Group {
                if viewModel.direction.source == .mandarin {
                    chineseInputControl
                } else {
                    Text(viewModel.direction.source.title)
                }
            }
            .frame(maxWidth: .infinity)

            Button("translator.swap_direction", systemImage: "arrow.left.arrow.right") {
                closeTextInput()
                viewModel.swapDirection()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier("swapDirection")

            Text(viewModel.direction.target.title)
                .frame(maxWidth: .infinity)
        }
        .font(.headline)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private var chineseInputControl: some View {
        Menu {
            Picker(
                "language.chinese_input",
                selection: Binding(get: { viewModel.chineseSpeechInput }, set: viewModel.selectChineseSpeechInput)
            ) {
                Text("language.mandarin").tag(ChineseSpeechInput.mandarin)
                Text("language.shanghainese_network").tag(ChineseSpeechInput.shanghainese)
            }
        } label: {
            HStack(spacing: 6) {
                VStack(spacing: 2) {
                    Text(viewModel.direction.source.title)
                    Text(viewModel.chineseSpeechInput.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.primary)
        .disabled(viewModel.isBusy)
        .accessibilityLabel("language.chinese_input")
        .accessibilityValue(Text(viewModel.chineseSpeechInput.title))
        .accessibilityIdentifier("chineseSpeechInput")
    }

    private func transcript(_ title: LocalizedStringKey, text: String, canReplay: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

                if !canReplay, !showsTextInput {
                    Spacer()
                    Button("translator.text_input", systemImage: "keyboard") {
                        textDraft = viewModel.sourceText
                        showsTextInput = true
                    }
                    .labelStyle(.iconOnly)
                    .disabled(viewModel.isBusy)
                } else if canReplay, !text.isEmpty {
                    Spacer()
                    Button("translator.replay", systemImage: "speaker.wave.2", action: viewModel.replay)
                        .labelStyle(.iconOnly)
                        .disabled(viewModel.isBusy || showsTextInput)
                }
            }

            if !canReplay, showsTextInput {
                textInputEditor
            } else if canReplay, viewModel.phase == .translating {
                ProgressView()
                    .accessibilityLabel("translator.translating_accessibility")
            } else if !canReplay, text.isEmpty, viewModel.phase == .recording {
                Text("translator.listening")
                    .foregroundStyle(.secondary)
            } else if !text.isEmpty {
                Text(text)
                    .font(.title2)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private var textInputEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("translator.text_input_placeholder", text: $textDraft, axis: .vertical)
                .font(.title3)
                .lineLimit(2...6)
                .focused($focusesTextInput)
                .accessibilityIdentifier("sourceTextInput")
                .onAppear { focusesTextInput = true }

            if viewModel.direction.source == .mandarin, viewModel.chineseSpeechInput == .shanghainese {
                Text("translator.shanghainese_dictation_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("common.cancel", action: closeTextInput)
                Spacer()
                Button("translator.translate") {
                    viewModel.translateText(textDraft)
                    closeTextInput()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func closeTextInput() {
        focusesTextInput = false
        showsTextInput = false
        textDraft = ""
    }
}
