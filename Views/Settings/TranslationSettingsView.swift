import SwiftUI

struct TranslationSettingsView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                Text("Translation provider and model used by the Translate button in the STT and TTS panels.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Provider", selection: $appState.translationProvider) {
                    ForEach(availableProviders) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Text(appState.translationProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if appState.translationProvider != .macOS {
                    Picker("Model", selection: $appState.selectedTranslationModel) {
                        ForEach(appState.translationProvider.availableModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            } header: {
                Text("Panel Translation")
            }

            Section {
                Text("Real-time translation for subtitle mode (STT). Active only when subtitle mode is enabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SubtitleTranslationSettings(appState: appState)
            } header: {
                Text("Subtitle Translation")
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible)
    }

    private var availableProviders: [TranslationProvider] {
        TranslationProvider.allCases.filter { provider in
            if !provider.requiresAPIKey { return provider.isAvailable }
            guard let envKey = provider.envKeyName else { return false }
            let apiKey = APIKeyManager.shared.getAPIKey(for: envKey)
            return apiKey != nil && !apiKey!.isEmpty
        }
    }
}

// MARK: - Subtitle Translation Settings

/// Subtitle Translation settings
struct SubtitleTranslationSettings: View {
    @Bindable var appState: AppState
    @State private var availableLanguages: [LanguageCode] = []
    @State private var isLoadingLanguages = true

    private var availableProviders: [TranslationProvider] {
        TranslationProvider.allCases.filter { provider in
            if !provider.requiresAPIKey { return provider.isAvailable }
            guard let envKey = provider.envKeyName else { return false }
            let apiKey = APIKeyManager.shared.getAPIKey(for: envKey)
            return apiKey != nil && !apiKey!.isEmpty
        }
    }

    private var isMacOSTranslationAvailable: Bool {
        TranslationFactory.isMacOSTranslationAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $appState.subtitleTranslationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Real-Time Translation")
                    Text("Translate subtitles to target language in real-time.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if !isMacOSTranslationAvailable && availableProviders.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Requires macOS 26+ for on-device translation, or set up API keys.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Picker("Provider", selection: $appState.subtitleTranslationProvider) {
                ForEach(availableProviders) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            Text(providerDescription)
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack {
                Text("Target Language")
                Spacer()
                if isLoadingLanguages {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Picker("", selection: $appState.subtitleTranslationLanguage) {
                        ForEach(availableLanguages) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            if appState.subtitleTranslationProvider == .macOS {
                Text("Only languages with installed language packs are shown. Install more in System Settings > General > Language & Region > Translation Languages.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Toggle(isOn: $appState.subtitleShowOriginal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Original Text")
                    Text("Display original text above the translation.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .task {
            await loadAvailableLanguages()
        }
        .onChange(of: appState.subtitleTranslationProvider) { _, _ in
            Task {
                await loadAvailableLanguages()
            }
        }
    }

    private func loadAvailableLanguages() async {
        isLoadingLanguages = true

        if appState.subtitleTranslationProvider == .macOS {
            availableLanguages = await MacOSTranslationAvailability.shared.getAvailableLanguages()

            if !availableLanguages.contains(appState.subtitleTranslationLanguage),
               let first = availableLanguages.first {
                appState.subtitleTranslationLanguage = first
            }
        } else {
            availableLanguages = LanguageCode.allCases.filter { $0 != .auto }
        }

        isLoadingLanguages = false
    }

    private var providerDescription: String {
        switch appState.subtitleTranslationProvider {
        case .macOS:
            return NSLocalizedString("Fast on-device translation. Requires macOS 26+.", comment: "Subtitle translation provider")
        case .openAI:
            return NSLocalizedString("OpenAI translation (100+ languages). Higher latency.", comment: "Subtitle translation provider")
        case .gemini:
            return NSLocalizedString("Gemini translation (100+ languages). Higher latency.", comment: "Subtitle translation provider")
        case .grok:
            return NSLocalizedString("Grok translation (100+ languages). Higher latency.", comment: "Subtitle translation provider")
        }
    }
}
