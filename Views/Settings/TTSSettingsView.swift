import SwiftUI

struct TTSSettingsView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                Picker("Provider", selection: $appState.selectedTTSProvider) {
                    ForEach(availableTTSProviders) { provider in
                        Text(provider.rawValue)
                            .tag(provider)
                    }
                }

                Text(appState.selectedTTSProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if availableTTSProviders.count < TTSProvider.allCases.count {
                    Text(NSLocalizedString("Set API keys in the API Keys section to enable more providers", comment: "API key hint"))
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                TTSModelPicker(appState: appState)
                TTSVoicePicker(appState: appState)
            } header: {
                Text("Provider & Voice")
            }

            Section {
                TTSSpeedSlider(appState: appState)
            } header: {
                Text("Playback")
            }

            Section {
                TTSLanguagePicker(appState: appState)
                AudioOutputDevicePicker(appState: appState)
            } header: {
                Text("Language & Output")
            }

            Section {
                TTSPanelBehaviorSettings(appState: appState)
            } header: {
                Text("Panel Behavior")
            }
        }
        .formStyle(.grouped)
    }

    private var availableTTSProviders: [TTSProvider] {
        TTSProvider.allCases.filter { provider in
            !provider.requiresAPIKey || hasTTSAPIKey(for: provider)
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
        case .grok:
            return appState.apiKeyManager.hasAPIKey(for: .grok)
        case .macOS:
            return true
        }
    }
}

// MARK: - TTS Component Views

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

/// Voice picker for TTS provider
struct TTSVoicePicker: View {
    @Bindable var appState: AppState
    @State private var availableVoices: [TTSVoice] = []
    @State private var isRefreshing = false

    var body: some View {
        HStack {
            Picker("Voice", selection: $appState.selectedTTSVoice) {
                if appState.selectedTTSProvider == .macOS {
                    ForEach(voicesWithSections, id: \.id) { item in
                        if item.isSection {
                            Divider()
                            Text(item.sectionTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let voice = item.voice {
                            Text(voiceDisplayName(voice))
                                .tag(voice.id)
                        }
                    }
                } else {
                    ForEach(availableVoices) { voice in
                        Text(voiceDisplayName(voice))
                            .tag(voice.id)
                    }
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
            loadVoices()
            refreshVoicesInBackgroundIfNeeded()
        }
    }

    private struct VoiceListItem: Identifiable {
        let id: String
        let voice: TTSVoice?
        let isSection: Bool
        let sectionTitle: String

        static func section(_ title: String) -> VoiceListItem {
            VoiceListItem(id: "section_\(title)", voice: nil, isSection: true, sectionTitle: title)
        }

        static func voice(_ voice: TTSVoice) -> VoiceListItem {
            VoiceListItem(id: voice.id, voice: voice, isSection: false, sectionTitle: "")
        }
    }

    private var hasMultipleQualityTiers: Bool {
        let nonDefaultVoices = availableVoices.filter { !$0.isDefault }
        let qualities = Set(nonDefaultVoices.map { $0.quality })
        return qualities.count > 1
    }

    private var voicesWithSections: [VoiceListItem] {
        var items: [VoiceListItem] = []
        var currentQuality: VoiceQuality?

        let showSeparators = hasMultipleQualityTiers

        for voice in availableVoices {
            if showSeparators && !voice.isDefault && voice.quality != currentQuality {
                currentQuality = voice.quality
                let title: String
                switch voice.quality {
                case .premium:
                    title = "── Premium ──"
                case .enhanced:
                    title = "── Enhanced ──"
                case .standard:
                    title = "── Standard ──"
                }
                items.append(.section(title))
            }
            items.append(.voice(voice))
        }

        return items
    }

    private func loadVoices() {
        let service = TTSFactory.makeService(for: appState.selectedTTSProvider)
        availableVoices = service.availableVoices()

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
        if voice.language.isEmpty ||
           appState.selectedTTSProvider == .openAI ||
           appState.selectedTTSProvider == .gemini {
            return voice.name
        } else {
            return "\(voice.name) (\(voice.language))"
        }
    }
}

/// Speed slider for TTS provider
struct TTSSpeedSlider: View {
    @Bindable var appState: AppState
    @State private var currentService: TTSService?

    private var speedRange: ClosedRange<Double> {
        0.5...2.0
    }

    private var supportsSpeed: Bool {
        switch appState.selectedTTSProvider {
        case .openAI:
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            return model != "gpt-4o-mini-tts"
        case .grok:
            return false
        case .macOS, .gemini, .elevenLabs:
            return true
        }
    }

    private var speedHelpText: String? {
        switch appState.selectedTTSProvider {
        case .openAI:
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            if model == "gpt-4o-mini-tts" {
                return "Speed control not available for GPT-4o Mini TTS. Use TTS-1 or TTS-1 HD for speed control."
            }
            return nil
        case .gemini:
            return "Gemini uses natural language pace control (approximate)."
        case .elevenLabs:
            return "ElevenLabs has limited speed range (0.7x-1.2x mapped)."
        case .grok:
            return "Grok Voice Agent does not support speed control."
        case .macOS:
            return nil
        }
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

            HStack(spacing: 8) {
                Slider(
                    value: $appState.selectedTTSSpeed,
                    in: speedRange,
                    step: 0.1
                ) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Slow")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } maximumValueLabel: {
                    Text("Fast")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .disabled(!supportsSpeed)
                .help(speedTooltip)

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

    private var speedTooltip: String {
        switch appState.selectedTTSProvider {
        case .openAI:
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            if model == "gpt-4o-mini-tts" {
                return "GPT-4o Mini TTS does not support speed control. Select TTS-1 or TTS-1 HD."
            }
            return "Adjust playback speed (0.25x–4.0x)"
        case .gemini:
            return "Gemini uses prompt-based pacing (approximate adjustment)"
        case .elevenLabs:
            return "Adjust playback speed (actual range: 0.7x–1.2x)"
        case .macOS:
            return "Adjust playback speed"
        case .grok:
            return "Grok Voice Agent does not support speed control"
        }
    }

    private var speedDisplayText: String {
        if !supportsSpeed {
            return "N/A"
        }
        return String(format: "%.1fx", appState.selectedTTSSpeed)
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

/// Audio output device picker for TTS (speaker selection)
struct AudioOutputDevicePicker: View {
    @Bindable var appState: AppState
    @State private var availableDevices: [AudioOutputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Audio Output", selection: $appState.selectedAudioOutputDeviceUID) {
                ForEach(availableDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }

            Text("Select the audio output device for speech playback.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            loadDevices()
        }
    }

    private func loadDevices() {
        availableDevices = AudioOutputManager.shared.availableOutputDevices()

        if !availableDevices.contains(where: { $0.uid == appState.selectedAudioOutputDeviceUID }) {
            appState.selectedAudioOutputDeviceUID = ""
        }
    }
}

/// TTS Panel behavior settings
struct TTSPanelBehaviorSettings: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $appState.ttsAutoSpeak) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-speak on panel open")
                    Text("When enabled, TTS starts speaking automatically when the panel opens with text.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
