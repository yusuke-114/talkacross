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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    directionControl
                    transcript("原文", text: viewModel.sourceText)
                    transcript("译文", text: viewModel.translatedText, canReplay: true)

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
                                Button("重试", action: viewModel.retryTranslation)
                            }
                            if viewModel.needsSystemSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                                Button("打开系统设置") { openURL(settings) }
                            }
                            if viewModel.needsAppSettings {
                                Button("设置") { showsSettings = true }
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
                    Button("示例", action: viewModel.translateExample)
                        .disabled(viewModel.isBusy || showsTextInput)
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") {
                        showsSettings = true
                    }
                    .disabled(viewModel.isBusy)
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
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

    private var microphoneControl: some View {
        let capturing = viewModel.isHoldingMicrophone
        let available = !viewModel.isBusy || capturing
        let recording = viewModel.phase == .recording
        let title: LocalizedStringKey = switch viewModel.phase {
        case .preparing: "正在准备…"
        case .recording: "松手结束"
        case .recognizing: "正在识别…"
        case .translating: "正在翻译…"
        case .speaking: "正在朗读…"
        case .idle: "按住说话"
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
            .accessibilityHint("轻点两次开始或结束录音")
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

            Button("切换方向", systemImage: "arrow.left.arrow.right") {
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
                "中文语音",
                selection: Binding(get: { viewModel.chineseSpeechInput }, set: viewModel.selectChineseSpeechInput)
            ) {
                Text("普通话").tag(ChineseSpeechInput.mandarin)
                Text("上海话（可能需联网）").tag(ChineseSpeechInput.shanghainese)
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
        .accessibilityLabel("中文语音")
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
                    Button("文字输入", systemImage: "keyboard") {
                        textDraft = viewModel.sourceText
                        showsTextInput = true
                    }
                    .labelStyle(.iconOnly)
                    .disabled(viewModel.isBusy)
                } else if canReplay, !text.isEmpty {
                    Spacer()
                    Button("重听", systemImage: "speaker.wave.2", action: viewModel.replay)
                        .labelStyle(.iconOnly)
                        .disabled(viewModel.isBusy || showsTextInput)
                }
            }

            if !canReplay, showsTextInput {
                textInputEditor
            } else if canReplay, viewModel.phase == .translating {
                ProgressView()
                    .accessibilityLabel("正在翻译")
            } else if !canReplay, text.isEmpty, viewModel.phase == .recording {
                Text("正在听…")
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
            TextField("输入或听写原文", text: $textDraft, axis: .vertical)
                .font(.title3)
                .lineLimit(2...6)
                .focused($focusesTextInput)
                .accessibilityIdentifier("sourceTextInput")
                .onAppear { focusesTextInput = true }

            if viewModel.direction.source == .mandarin, viewModel.chineseSpeechInput == .shanghainese {
                Text("上海话可用系统键盘听写，可能需要联网。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("取消", action: closeTextInput)
                Spacer()
                Button("翻译") {
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
