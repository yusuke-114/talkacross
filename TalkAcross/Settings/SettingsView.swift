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
                    Section("voice_setup.title") {
                        ForEach(priorityResources, id: \.self) { resource in
                            priorityRow(for: resource)
                        }
                    }
                }
                Section("settings.translation_languages") {
                    ForEach(TranslationDirection.allCases.filter { !priorityResources.contains(.translation($0)) }, id: \.self) {
                        translationRow($0)
                    }
                }
                Section("settings.apple_speech_resources") {
                    ForEach(SpokenLanguage.allCases.filter { !priorityResources.contains(.appleSpeech($0)) }, id: \.self) {
                        speechRow($0)
                    }
                }
                Section("settings.system_voices") {
                    ForEach(SpokenLanguage.allCases.filter { !priorityResources.contains(.voice($0)) }, id: \.self) {
                        voiceRow($0)
                    }
                }
                Section("settings.speech_engines") {
                    Picker(
                        "settings.speech_engine",
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
                        Text("settings.shanghainese_pack")
                    } footer: {
                        Text("settings.shanghainese_pack_help")
                    }
                }
                Section {
                    NavigationLink("settings.privacy_policy") {
                        PrivacyPolicyView()
                    }
                }
            }
            .navigationTitle("common.settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
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
                    Text(available ? LocalizedStringKey("common.ready") : "settings.add_voice_in_system_settings")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .accessibilityLabel("common.checking")
                }
            }
            if viewModel.voiceAvailability[language] == false {
                Text("settings.add_system_voice_instructions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var whisperModelRows: some View {
        Picker(
            "settings.whisper_model",
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
                Text("settings.shanghainese_to_mandarin")
                Text("settings.shanghainese_pack_size")
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
            Text("common.ready").foregroundStyle(.secondary)
            Button("common.delete", role: .destructive) {
                Task { await viewModel.removeShanghainesePack() }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("removeShanghainesePack")
        case .missing:
            Button(viewModel.shanghaineseMessage == nil ? LocalizedStringKey("common.download") : "common.retry_download") {
                Task { await viewModel.downloadShanghainesePack() }
            }
            .accessibilityIdentifier("downloadShanghainesePack")
        case .downloading:
            downloadProgress(viewModel.shanghaineseProgress, title: "common.downloading")
        case nil:
            ProgressView()
                .accessibilityLabel("common.checking")
        }
    }

    @ViewBuilder
    private var whisperModelControl: some View {
        switch viewModel.modelStatus {
        case .ready:
            Button("settings.delete_model", role: .destructive) {
                Task { await viewModel.removeModel() }
            }
        case .missing:
            Button(viewModel.modelMessage == nil ? LocalizedStringKey("common.download") : "common.retry_download") {
                Task { await viewModel.downloadModel() }
            }
        case .preparing:
            if let progress = viewModel.modelProgress {
                downloadProgress(progress, title: "common.downloading")
            } else {
                ProgressView("common.preparing")
            }
        case nil:
            ProgressView()
                .accessibilityLabel("common.checking")
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
                .accessibilityLabel("settings.preparing_speech_resources")
        } else {
            switch viewModel.speechStatuses[language] {
            case .installed:
                Text("common.ready").foregroundStyle(.secondary)
            case .supported:
                Button(viewModel.failedSpeech == language ? LocalizedStringKey("common.retry") : "common.download") {
                    Task { await viewModel.downloadSpeech(for: language) }
                }
                .disabled(viewModel.preparingSpeech != nil)
            case .downloading:
                Text("common.downloading").foregroundStyle(.secondary)
            case nil:
                ProgressView()
                    .accessibilityLabel("common.checking")
            default:
                Text("common.unavailable").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func translationStatus(for direction: TranslationDirection) -> some View {
        if viewModel.downloading == direction {
            ProgressView()
                .accessibilityLabel("settings.preparing_translation_languages")
        } else {
            switch viewModel.translationStatuses[direction] {
            case .installed:
                Text("common.ready")
                    .foregroundStyle(.secondary)
            case .supported:
                Button(viewModel.failedDownload == direction ? LocalizedStringKey("common.retry") : "common.download") {
                    viewModel.requestDownload(for: direction)
                }
                .disabled(viewModel.downloading != nil)
            case nil:
                ProgressView()
                    .accessibilityLabel("common.checking")
            default:
                Text("common.unavailable")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
