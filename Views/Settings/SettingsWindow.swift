import SwiftUI

struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ShortcutSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            APISettingsView()
                .tabItem {
                    Label("API Keys", systemImage: "key")
                }
        }
        .frame(width: 500, height: 450)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            // STT Section
            Section {
                Picker("STT Provider", selection: $appState.selectedRealtimeProvider) {
                    ForEach(availableSTTProviders) { provider in
                        Text(provider.rawValue)
                            .tag(provider)
                    }
                }
                // Note: Model is automatically reset in AppState when provider changes

                Text(appState.selectedRealtimeProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if availableSTTProviders.count < RealtimeSTTProvider.allCases.count {
                    Text("API Keysタブでキーを設定すると他のプロバイダも選択可能になります")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                // STT Model selection
                STTModelPicker(appState: appState)

                // STT Language selection
                STTLanguagePicker(appState: appState)
            } header: {
                Text("Speech-to-Text")
            }

            // TTS Section
            Section {
                Picker("TTS Provider", selection: $appState.selectedTTSProvider) {
                    ForEach(availableTTSProviders) { provider in
                        Text(provider.rawValue)
                            .tag(provider)
                    }
                }
                // Note: Voice and model are automatically reset in AppState when provider changes

                Text(appState.selectedTTSProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if availableTTSProviders.count < TTSProvider.allCases.count {
                    Text("API Keysタブでキーを設定すると他のプロバイダも選択可能になります")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                // Model selection based on provider
                TTSModelPicker(appState: appState)

                // Voice selection based on provider
                TTSVoicePicker(appState: appState)

                // Speed control
                TTSSpeedSlider(appState: appState)

                // Word highlight toggle
                TTSWordHighlightToggle(appState: appState)

                // TTS Language selection (ElevenLabs only)
                TTSLanguagePicker(appState: appState)
            } header: {
                Text("Text-to-Speech")
            }

            // Startup Section
            Section {
                LaunchAtLoginToggle()
            } header: {
                Text("Startup")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // Available STT providers (only those with API keys or not requiring them)
    private var availableSTTProviders: [RealtimeSTTProvider] {
        RealtimeSTTProvider.allCases.filter { provider in
            !provider.requiresAPIKey || hasSTTAPIKey(for: provider)
        }
    }

    // Available TTS providers (only those with API keys or not requiring them)
    private var availableTTSProviders: [TTSProvider] {
        TTSProvider.allCases.filter { provider in
            !provider.requiresAPIKey || hasTTSAPIKey(for: provider)
        }
    }

    private func hasSTTAPIKey(for provider: RealtimeSTTProvider) -> Bool {
        guard provider.envKeyName != nil else { return true }
        switch provider {
        case .openAI:
            return appState.apiKeyManager.hasAPIKey(for: .openAI)
        case .gemini:
            return appState.apiKeyManager.hasAPIKey(for: .gemini)
        case .elevenLabs:
            return appState.apiKeyManager.hasAPIKey(for: .elevenLabs)
        case .macOS:
            return true
        }
    }

    private func hasTTSAPIKey(for provider: TTSProvider) -> Bool {
        guard provider.envKeyName != nil else { return true }
        switch provider {
        case .openAI:
            return appState.apiKeyManager.hasAPIKey(for: .openAI)
        case .gemini:
            return appState.apiKeyManager.hasAPIKey(for: .gemini)
        case .elevenLabs:
            return appState.apiKeyManager.hasAPIKey(for: .elevenLabs)
        case .macOS:
            return true
        }
    }
}

struct ShortcutSettingsView: View {
    @Environment(AppState.self) var appState
    @State private var sttKeyCombo: KeyCombo = .sttDefault
    @State private var ttsKeyCombo: KeyCombo = .ttsDefault

    var body: some View {
        Form {
            Section {
                ShortcutRecorderView(title: "Start/Stop Recording (STT)", keyCombo: $sttKeyCombo)
                    .onChange(of: sttKeyCombo) { _, newValue in
                        appState.hotKeyService?.sttKeyCombo = newValue
                    }

                ShortcutRecorderView(title: "Read Selected Text (TTS)", keyCombo: $ttsKeyCombo)
                    .onChange(of: ttsKeyCombo) { _, newValue in
                        appState.hotKeyService?.ttsKeyCombo = newValue
                    }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click on a shortcut and press a new key combination to change it. Shortcuts must include at least one modifier key (⌘, ⌥, ⌃, or ⇧).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Reset to Defaults") {
                    sttKeyCombo = .sttDefault
                    ttsKeyCombo = .ttsDefault
                    appState.hotKeyService?.sttKeyCombo = .sttDefault
                    appState.hotKeyService?.ttsKeyCombo = .ttsDefault
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // Load current shortcuts from hotKeyService
            if let service = appState.hotKeyService {
                sttKeyCombo = service.sttKeyCombo
                ttsKeyCombo = service.ttsKeyCombo
            }
        }
    }
}

/// Voice picker for TTS provider
struct TTSVoicePicker: View {
    @Bindable var appState: AppState
    @State private var availableVoices: [TTSVoice] = []
    @State private var isRefreshing = false

    var body: some View {
        HStack {
            Picker("Voice", selection: $appState.selectedTTSVoice) {
                ForEach(availableVoices) { voice in
                    Text(voiceDisplayName(voice))
                        .tag(voice.id)
                }
            }

            if appState.selectedTTSProvider == .elevenLabs {
                Button(action: refreshVoices) {
                    if isRefreshing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh voice list from API")
            }
        }
        .onAppear {
            loadVoices()
            refreshVoicesInBackgroundIfNeeded()
        }
        .onChange(of: appState.selectedTTSProvider) { _, _ in
            // Reset voice when provider changes
            loadVoices()
            refreshVoicesInBackgroundIfNeeded()
        }
    }

    private func loadVoices() {
        let service = TTSFactory.makeService(for: appState.selectedTTSProvider)
        availableVoices = service.availableVoices()

        // If current voice is not in the list, select the default or first voice
        if !availableVoices.contains(where: { $0.id == appState.selectedTTSVoice }) {
            if let defaultVoice = availableVoices.first(where: { $0.isDefault }) {
                appState.selectedTTSVoice = defaultVoice.id
            } else if let firstVoice = availableVoices.first {
                appState.selectedTTSVoice = firstVoice.id
            }
        }
    }

    private func refreshVoicesInBackgroundIfNeeded() {
        guard appState.selectedTTSProvider == .elevenLabs else { return }
        guard TTSVoiceCache.shared.isCacheExpired(for: .elevenLabs) else { return }

        Task {
            await ElevenLabsTTS.fetchAndCacheVoices()
            loadVoices()
        }
    }

    private func refreshVoices() {
        guard appState.selectedTTSProvider == .elevenLabs else { return }

        isRefreshing = true
        Task {
            await ElevenLabsTTS.fetchAndCacheVoices()
            loadVoices()
            isRefreshing = false
        }
    }

    private func voiceDisplayName(_ voice: TTSVoice) -> String {
        if voice.language.isEmpty {
            return voice.name
        } else {
            return "\(voice.name) (\(voice.language))"
        }
    }
}

/// Model picker for STT provider
struct STTModelPicker: View {
    @Bindable var appState: AppState
    @State private var availableModels: [RealtimeSTTModelInfo] = []

    var body: some View {
        Picker("Model", selection: $appState.selectedRealtimeSTTModel) {
            ForEach(availableModels) { model in
                Text(modelDisplayName(model))
                    .tag(model.id)
            }
        }
        .onAppear {
            loadModels()
        }
        .onChange(of: appState.selectedRealtimeProvider) { _, _ in
            loadModels()
        }
    }

    private func loadModels() {
        let service = RealtimeSTTFactory.makeService(for: appState.selectedRealtimeProvider)
        availableModels = service.availableModels()

        // If current model is not in the list, select the default or first model
        if !availableModels.contains(where: { $0.id == appState.selectedRealtimeSTTModel }) {
            if let defaultModel = availableModels.first(where: { $0.isDefault }) {
                appState.selectedRealtimeSTTModel = defaultModel.id
            } else if let firstModel = availableModels.first {
                appState.selectedRealtimeSTTModel = firstModel.id
            }
        }
    }

    private func modelDisplayName(_ model: RealtimeSTTModelInfo) -> String {
        if model.description.isEmpty {
            return model.name
        } else {
            return "\(model.name) - \(model.description)"
        }
    }
}

/// Model picker for TTS provider
struct TTSModelPicker: View {
    @Bindable var appState: AppState
    @State private var availableModels: [TTSModelInfo] = []

    var body: some View {
        Picker("Model", selection: $appState.selectedTTSModel) {
            ForEach(availableModels) { model in
                Text(modelDisplayName(model))
                    .tag(model.id)
            }
        }
        .onAppear {
            loadModels()
        }
        .onChange(of: appState.selectedTTSProvider) { _, _ in
            loadModels()
        }
    }

    private func loadModels() {
        let service = TTSFactory.makeService(for: appState.selectedTTSProvider)
        availableModels = service.availableModels()

        // If current model is not in the list, select the default or first model
        if !availableModels.contains(where: { $0.id == appState.selectedTTSModel }) {
            if let defaultModel = availableModels.first(where: { $0.isDefault }) {
                appState.selectedTTSModel = defaultModel.id
            } else if let firstModel = availableModels.first {
                appState.selectedTTSModel = firstModel.id
            }
        }
    }

    private func modelDisplayName(_ model: TTSModelInfo) -> String {
        if model.description.isEmpty {
            return model.name
        } else {
            return "\(model.name) - \(model.description)"
        }
    }
}

/// Speed slider for TTS provider
struct TTSSpeedSlider: View {
    @Bindable var appState: AppState
    @State private var currentService: TTSService?

    // Get speed range for current provider
    private var speedRange: ClosedRange<Double> {
        // Use a standard range for UI, actual conversion happens in each provider
        0.5...2.0
    }

    private var supportsSpeed: Bool {
        // OpenAI gpt-4o-mini-tts (default when empty) doesn't support speed
        if appState.selectedTTSProvider == .openAI {
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            return model != "gpt-4o-mini-tts"
        }
        return true
    }

    private var speedHelpText: String? {
        if appState.selectedTTSProvider == .openAI {
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            if model == "gpt-4o-mini-tts" {
                return "Speed control not available for GPT-4o Mini TTS. Use TTS-1 or TTS-1 HD for speed control."
            }
        }
        if appState.selectedTTSProvider == .gemini {
            return "Gemini uses natural language pace control (approximate)."
        }
        if appState.selectedTTSProvider == .elevenLabs {
            return "ElevenLabs has limited speed range (0.7x-1.2x mapped)."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speed")
                Spacer()
                Text(speedDisplayText)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            HStack {
                Text("Slow")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Slider(
                    value: $appState.selectedTTSSpeed,
                    in: speedRange,
                    step: 0.1
                )
                .disabled(!supportsSpeed)
                .help(speedTooltip)

                Text("Fast")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button("Reset") {
                    appState.selectedTTSSpeed = 1.0
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let helpText = speedHelpText {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // Tooltip text for speed slider
    private var speedTooltip: String {
        switch appState.selectedTTSProvider {
        case .openAI:
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            if model == "gpt-4o-mini-tts" {
                return "GPT-4o Mini TTSは速度制御非対応です。TTS-1またはTTS-1 HDを選択してください。"
            }
            return "再生速度を調整 (0.25x〜4.0x)"
        case .gemini:
            return "Geminiはプロンプトでペースを制御します（おおよその調整）"
        case .elevenLabs:
            return "再生速度を調整 (実際の範囲: 0.7x〜1.2x)"
        case .macOS:
            return "再生速度を調整"
        }
    }

    private var speedDisplayText: String {
        if !supportsSpeed {
            return "N/A"
        }
        return String(format: "%.1fx", appState.selectedTTSSpeed)
    }
}

/// Toggle for launch at login setting
struct LaunchAtLoginToggle: View {
    @State private var isEnabled: Bool = LaunchAtLoginService.shared.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at Login", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in
                    LaunchAtLoginService.shared.isEnabled = newValue
                }
                .disabled(!LaunchAtLoginService.shared.isAvailable)

            if LaunchAtLoginService.shared.isAvailable {
                Text("TypeTalk will start automatically when you log in")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Launch at login requires macOS 13 or later")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            // Sync state on appear
            isEnabled = LaunchAtLoginService.shared.isEnabled
        }
    }
}

/// Toggle for TTS word highlighting
struct TTSWordHighlightToggle: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Word Highlighting", isOn: $appState.enableWordHighlight)

            Text("Highlight the current word being spoken during TTS playback")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Language picker for STT provider
struct STTLanguagePicker: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Language", selection: $appState.selectedSTTLanguage) {
                ForEach(LanguageCode.allCases) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }

            Text(languageHelpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var languageHelpText: String {
        switch appState.selectedRealtimeProvider {
        case .macOS:
            return "Specifies the expected language for speech recognition."
        case .openAI:
            return "Helps improve accuracy. Auto uses automatic detection."
        case .gemini:
            return "Gemini auto-detects language (setting ignored)."
        case .elevenLabs:
            return "Specifies the input language for transcription."
        }
    }
}

/// Language picker for TTS provider (only shown for ElevenLabs)
struct TTSLanguagePicker: View {
    @Bindable var appState: AppState

    var body: some View {
        if appState.selectedTTSProvider == .elevenLabs {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Language", selection: $appState.selectedTTSLanguage) {
                    ForEach(LanguageCode.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }

                Text("Specifies the output language for speech synthesis.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
