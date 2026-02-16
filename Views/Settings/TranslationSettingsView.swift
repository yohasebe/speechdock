import SwiftUI

struct TranslationSettingsView: View {
    @Environment(AppState.self) var appState
    @State private var availableLanguages: [LanguageCode] = []
    @State private var isLoadingLanguages = true

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                Text("Translation provider, model, and target language used by both the panel Translate button and subtitle real-time translation.")
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

                HStack {
                    Text("Target Language")
                    Spacer()
                    if isLoadingLanguages {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Picker("", selection: $appState.translationTargetLanguage) {
                            ForEach(availableLanguages) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }

                if appState.translationProvider == .macOS {
                    Text("Only languages with installed language packs are shown. Install more in System Settings > General > Language & Region > Translation Languages.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Translation")
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
        .task {
            await loadAvailableLanguages()
        }
        .onChange(of: appState.translationProvider) { _, _ in
            Task {
                await loadAvailableLanguages()
            }
        }
    }

    private var availableProviders: [TranslationProvider] {
        TranslationProvider.allCases.filter { provider in
            if !provider.requiresAPIKey { return provider.isAvailable }
            guard let envKey = provider.envKeyName else { return false }
            let apiKey = APIKeyManager.shared.getAPIKey(for: envKey)
            return apiKey != nil && !apiKey!.isEmpty
        }
    }

    private func loadAvailableLanguages() async {
        isLoadingLanguages = true

        if appState.translationProvider == .macOS {
            availableLanguages = await MacOSTranslationAvailability.shared.getAvailableLanguages()

            if !availableLanguages.contains(appState.translationTargetLanguage),
               let first = availableLanguages.first {
                appState.translationTargetLanguage = first
            }
        } else {
            availableLanguages = LanguageCode.allCases.filter { $0 != .auto }
        }

        isLoadingLanguages = false
    }
}

// MARK: - Subtitle Translation Settings

/// Subtitle Translation settings (provider & language are now in main Translation section)
struct SubtitleTranslationSettings: View {
    @Bindable var appState: AppState

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

            Toggle(isOn: $appState.subtitleShowOriginal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Original Text")
                    Text("Display original text above the translation.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
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
