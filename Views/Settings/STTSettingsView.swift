import SwiftUI

struct STTSettingsView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                Picker("Provider", selection: $appState.selectedRealtimeProvider) {
                    ForEach(availableSTTProviders) { provider in
                        Text(provider.rawValue)
                            .tag(provider)
                    }
                }

                Text(appState.selectedRealtimeProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if availableSTTProviders.count < RealtimeSTTProvider.allCases.count {
                    Text(NSLocalizedString("Set API keys in the API Keys section to enable more providers", comment: "API key hint"))
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                STTModelPicker(appState: appState)
                STTLanguagePicker(appState: appState)
            } header: {
                Text("Provider & Model")
            }

            Section {
                AudioInputSourcePicker(appState: appState)
                AudioInputDevicePicker(appState: appState)
            } header: {
                Text("Audio Input")
            }

            Section {
                VADAutoStopSettings(appState: appState)
                STTPanelBehaviorSettings(appState: appState)
            } header: {
                Text("Recording & Panel")
            }
        }
        .formStyle(.grouped)
    }

    private var availableSTTProviders: [RealtimeSTTProvider] {
        RealtimeSTTProvider.allCases.filter { provider in
            !provider.requiresAPIKey || hasSTTAPIKey(for: provider)
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
        case .grok:
            return appState.apiKeyManager.hasAPIKey(for: .grok)
        case .macOS:
            return true
        }
    }
}

// MARK: - STT Component Views

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

/// Language picker for STT provider
struct STTLanguagePicker: View {
    @Bindable var appState: AppState

    private var supportedLanguages: [LanguageCode] {
        LanguageCode.supportedLanguages(for: appState.selectedRealtimeProvider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Language", selection: $appState.selectedSTTLanguage) {
                ForEach(supportedLanguages) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .onAppear {
                ensureValidLanguageSelection()
            }
            .onChange(of: appState.selectedRealtimeProvider) { _, newProvider in
                let supported = LanguageCode.supportedLanguages(for: newProvider)
                if let currentLang = LanguageCode(rawValue: appState.selectedSTTLanguage),
                   !supported.contains(currentLang) {
                    appState.selectedSTTLanguage = LanguageCode.defaultLanguage(for: newProvider).rawValue
                } else if appState.selectedSTTLanguage.isEmpty && !LanguageCode.supportsAutoDetection(for: newProvider) {
                    appState.selectedSTTLanguage = LanguageCode.defaultLanguage(for: newProvider).rawValue
                }
            }

            Text(languageHelpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func ensureValidLanguageSelection() {
        let supported = supportedLanguages

        if let currentLang = LanguageCode(rawValue: appState.selectedSTTLanguage) {
            if supported.contains(currentLang) {
                return
            }
        }

        appState.selectedSTTLanguage = LanguageCode.defaultLanguage(for: appState.selectedRealtimeProvider).rawValue
    }

    private var languageHelpText: String {
        switch appState.selectedRealtimeProvider {
        case .macOS:
            return NSLocalizedString("Auto uses system locale. Select a specific language for better accuracy.", comment: "STT language help")
        case .openAI:
            return NSLocalizedString("Auto detects the language. Specifying a language can improve accuracy.", comment: "STT language help")
        case .gemini:
            return NSLocalizedString("Auto detects the language. Note: Portuguese is not supported.", comment: "STT language help")
        case .elevenLabs:
            return NSLocalizedString("Auto detects the language. Specifying a language can improve accuracy.", comment: "STT language help")
        case .grok:
            return NSLocalizedString("Auto detects the language (100+ languages supported).", comment: "STT language help")
        }
    }
}

/// Audio input source picker for STT (Microphone, System Audio only in Settings)
struct AudioInputSourcePicker: View {
    @Bindable var appState: AppState

    private let availableSourceTypes: [AudioInputSourceType] = [.microphone, .systemAudio]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Audio Source", selection: $appState.selectedAudioInputSourceType) {
                ForEach(availableSourceTypes) { sourceType in
                    Label(sourceType.rawValue, systemImage: sourceType.icon)
                        .tag(sourceType)
                }
            }

            Text(appState.selectedAudioInputSourceType.description)
                .font(.caption)
                .foregroundColor(.secondary)

            if appState.selectedAudioInputSourceType == .systemAudio {
                Text("System Audio requires Screen Recording permission.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text("App-specific audio capture is available in the menu bar and STT panel.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear {
            if appState.selectedAudioInputSourceType == .applicationAudio {
                appState.selectedAudioInputSourceType = .microphone
            }
        }
    }
}

/// Audio input device picker for STT (microphone selection)
struct AudioInputDevicePicker: View {
    @Bindable var appState: AppState
    @State private var availableDevices: [AudioInputDevice] = []

    var body: some View {
        if appState.selectedAudioInputSourceType == .microphone {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Microphone", selection: $appState.selectedAudioInputDeviceUID) {
                    ForEach(availableDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Text("Select the microphone device for speech recognition.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .onAppear {
                loadDevices()
            }
        }
    }

    private func loadDevices() {
        availableDevices = appState.audioInputManager.availableInputDevices()

        if !availableDevices.contains(where: { $0.uid == appState.selectedAudioInputDeviceUID }) {
            appState.selectedAudioInputDeviceUID = ""
        }
    }
}

/// VAD Auto-Stop settings (only shown for providers that use VAD)
struct VADAutoStopSettings: View {
    @Bindable var appState: AppState

    private var supportsVADAutoStop: Bool {
        [.gemini, .openAI].contains(appState.selectedRealtimeProvider)
    }

    var body: some View {
        if supportsVADAutoStop {
            VStack(alignment: .leading, spacing: 12) {
                Text("Auto-Stop Settings")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min. recording time")
                        Spacer()
                        Text("\(Int(appState.vadMinimumRecordingTime))s")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    HStack {
                        Text("5s")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Slider(
                            value: $appState.vadMinimumRecordingTime,
                            in: 5...60,
                            step: 5
                        )

                        Text("60s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Text("Recording must reach this duration before auto-stop activates.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Silence duration")
                        Spacer()
                        Text("\(Int(appState.vadSilenceDuration))s")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    HStack {
                        Text("1s")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Slider(
                            value: $appState.vadSilenceDuration,
                            in: 1...10,
                            step: 1
                        )

                        Text("10s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Text("Duration of silence required to trigger auto-stop.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        appState.vadMinimumRecordingTime = 10.0
                        appState.vadSilenceDuration = 3.0
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// STT Panel behavior settings
struct STTPanelBehaviorSettings: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Panel Behavior")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Toggle(isOn: $appState.sttAutoStart) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-start recording")
                    Text("When enabled, recording starts automatically when the STT panel opens.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Toggle(isOn: $appState.closePanelAfterPaste) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Close panel after paste")
                    Text("When enabled, the STT panel closes automatically after pasting text.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}
