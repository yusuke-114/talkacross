import Speech
import SwiftUI
import Translation

struct SettingsView: View {
    var priorityResources: [VoiceResource] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            List {
                if !priorityResources.isEmpty {
                    Section("准备语音翻译") {
                        ForEach(priorityResources, id: \.self) { resource in
                            priorityRow(for: resource)
                        }
                    }
                }
                Section("翻译语言") {
                    ForEach(TranslationDirection.allCases.filter { !priorityResources.contains(.translation($0)) }, id: \.self) {
                        translationRow($0)
                    }
                }
                Section("Apple 原生识别") {
                    ForEach(SpokenLanguage.allCases.filter { !priorityResources.contains(.appleSpeech($0)) }, id: \.self) {
                        speechRow($0)
                    }
                }
                Section("系统朗读语音") {
                    ForEach(SpokenLanguage.allCases.filter { !priorityResources.contains(.voice($0)) }, id: \.self) {
                        voiceRow($0)
                    }
                }
                Section("普通话和日语识别") {
                    Picker(
                        "引擎",
                        selection: Binding(get: { viewModel.engine }, set: viewModel.selectEngine)
                    ) {
                        ForEach(SpeechEngine.allCases, id: \.self) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                }
                if !priorityResources.contains(.whisperModel) {
                    Section("WhisperKit") { whisperModelRows }
                }
                if !priorityResources.contains(.shanghainesePack) {
                    Section {
                        shanghainesePackRows
                    } header: {
                        Text("上海话转换包")
                    } footer: {
                        Text("上海话录音和文字输入需要此转换包。下载后，上海话在设备上转成普通话，再翻译成日语。")
                    }
                }
                Section {
                    NavigationLink("隐私政策") {
                        PrivacyPolicyView()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: scenePhase) {
                if scenePhase == .active {
                    await viewModel.refresh()
                }
            }
            .task(id: viewModel.model) {
                await viewModel.refreshModelStatus()
            }
            .task(id: viewModel.modelStatus == .preparing) {
                while viewModel.modelStatus == .preparing {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    await viewModel.refreshModelStatus()
                }
            }
            .task(id: viewModel.shanghaineseStatus == .downloading) {
                while viewModel.shanghaineseStatus == .downloading {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    await viewModel.refreshShanghaineseStatus()
                }
            }
            .task(id: viewModel.hasSpeechDownloadInProgress && scenePhase == .active) {
                // A download started on a previous Settings page only updates that page's model.
                guard scenePhase == .active else { return }
                while viewModel.hasSpeechDownloadInProgress {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    await viewModel.refreshSpeechStatuses()
                }
            }
            .translationTask(viewModel.downloadConfiguration) { session in
                await viewModel.prepareTranslation(using: session)
            }
        }
    }

    @ViewBuilder
    private func priorityRow(for resource: VoiceResource) -> some View {
        switch resource {
        case .translation(let direction):
            translationRow(direction, title: resource.title)
        case .appleSpeech(let language):
            speechRow(language, title: resource.title)
        case .whisperModel:
            whisperModelRows
        case .shanghainesePack:
            shanghainesePackRows
        case .voice(let language):
            voiceRow(language, title: resource.title)
        }
    }

    private func translationRow(_ direction: TranslationDirection, title: String? = nil) -> some View {
        HStack {
            Text(verbatim: title ?? "\(direction.source.title) → \(direction.target.title)")
            Spacer()
            translationStatus(for: direction)
        }
    }

    private func speechRow(_ language: SpokenLanguage, title: String? = nil) -> some View {
        HStack {
            Text(title ?? language.title)
            Spacer()
            speechStatus(for: language)
        }
    }

    private func voiceRow(_ language: SpokenLanguage, title: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title ?? language.title)
                Spacer()
                if let available = viewModel.voiceAvailability[language] {
                    Text(available ? LocalizedStringKey("已就绪") : "请在系统设置中添加")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .accessibilityLabel("正在检查")
                }
            }
            if viewModel.voiceAvailability[language] == false {
                Text("在 iPhone 的「设置 → 辅助功能 → 阅读与朗读 → 语音」中添加此语言的语音。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var whisperModelRows: some View {
        Picker(
            "WhisperKit 模型",
            selection: Binding(get: { viewModel.model }, set: viewModel.selectModel)
        ) {
            ForEach(WhisperModel.allCases, id: \.self) { model in
                Text(model.title).tag(model)
            }
        }
        HStack {
            Text(viewModel.model.downloadSize)
                .foregroundStyle(.secondary)
            Spacer()
            whisperModelControl
        }
        if let message = viewModel.modelMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var shanghainesePackRows: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("上海话 → 普通话")
                Text("约 310 MB")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            shanghainesePackControl
        }
        if let message = viewModel.shanghaineseMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var shanghainesePackControl: some View {
        switch viewModel.shanghaineseStatus {
        case .ready:
            Text("已就绪").foregroundStyle(.secondary)
            Button("删除", role: .destructive) {
                Task { await viewModel.removeShanghainesePack() }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("removeShanghainesePack")
        case .missing:
            Button(viewModel.shanghaineseMessage == nil ? LocalizedStringKey("下载") : "重试下载") {
                Task { await viewModel.downloadShanghainesePack() }
            }
            .accessibilityIdentifier("downloadShanghainesePack")
        case .downloading:
            downloadProgress(viewModel.shanghaineseProgress, title: "下载中")
        case nil:
            ProgressView()
                .accessibilityLabel("正在检查")
        }
    }

    @ViewBuilder
    private var whisperModelControl: some View {
        switch viewModel.modelStatus {
        case .ready:
            Button("删除模型", role: .destructive) {
                Task { await viewModel.removeModel() }
            }
        case .missing:
            Button(viewModel.modelMessage == nil ? LocalizedStringKey("下载") : "重试下载") {
                Task { await viewModel.downloadModel() }
            }
        case .preparing:
            if let progress = viewModel.modelProgress {
                downloadProgress(progress, title: "下载中")
            } else {
                ProgressView("正在准备…")
            }
        case nil:
            ProgressView()
                .accessibilityLabel("正在检查")
        }
    }

    @ViewBuilder
    private func downloadProgress(_ fraction: Double?, title: LocalizedStringKey) -> some View {
        if let fraction {
            ProgressView(value: fraction) {
                Text(title)
            } currentValueLabel: {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .frame(width: 120)
        } else {
            ProgressView(title)
        }
    }

    @ViewBuilder
    private func speechStatus(for language: SpokenLanguage) -> some View {
        if viewModel.preparingSpeech == language {
            ProgressView()
                .accessibilityLabel("正在准备识别资源")
        } else {
            switch viewModel.speechStatuses[language] {
            case .installed:
                Text("已就绪").foregroundStyle(.secondary)
            case .supported:
                Button(viewModel.failedSpeech == language ? LocalizedStringKey("重试") : "下载") {
                    Task { await viewModel.downloadSpeech(for: language) }
                }
                .disabled(viewModel.preparingSpeech != nil)
            case .downloading:
                Text("下载中").foregroundStyle(.secondary)
            case nil:
                ProgressView()
                    .accessibilityLabel("正在检查")
            default:
                Text("不可用").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func translationStatus(for direction: TranslationDirection) -> some View {
        if viewModel.downloading == direction {
            ProgressView()
                .accessibilityLabel("正在准备翻译语言")
        } else {
            switch viewModel.translationStatuses[direction] {
            case .installed:
                Text("已就绪")
                    .foregroundStyle(.secondary)
            case .supported:
                Button(viewModel.failedDownload == direction ? LocalizedStringKey("重试") : "下载") {
                    viewModel.requestDownload(for: direction)
                }
                .disabled(viewModel.downloading != nil)
            case nil:
                ProgressView()
                    .accessibilityLabel("正在检查")
            default:
                Text("不可用")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
