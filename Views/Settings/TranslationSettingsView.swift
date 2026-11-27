import SwiftUI

struct TranslationSettingsView: View {
    @Environment(AppState.self) var appState
    @State private var availableLanguages: [LanguageCode] = []
    @State private var isLoadingLanguages = true

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                Text("The provider and target language apply to both the panel Translate button and subtitle translation. The model applies to the panel; subtitles use the provider's default model for speed.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                Picker("Provider", selection: $appState.translationProvider) {
                    ForEach(availableProviders) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Text(appState.translationProvider.description)
                    .font(.callout)
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
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Translation")
            }

            Section {
                Text("Real-time translation for subtitle mode (STT). Active only when subtitle mode is enabled.")
                    .font(.callout)
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
            return APIKeyManager.shared.hasAPIKey(for: envKey)
        }
    }

    private func loadAvailableLanguages() async {
        isLoadingLanguages = true
        availableLanguages = await appState.translationProvider.availableTranslationLanguages()

        if !availableLanguages.contains(appState.translationTargetLanguage),
           let first = availableLanguages.first {
            appState.translationTargetLanguage = first
        }

        isLoadingLanguages = false
    }
}

// MARK: - Subtitle Translation Settings

/// Subtitle Translation settings (provider & language are shared from main Translation section)
struct SubtitleTranslationSettings: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $appState.subtitleTranslationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Real-Time Translation")
                    Text("Translate subtitles to target language in real-time.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            Toggle(isOn: $appState.subtitleShowOriginal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Original Text")
                    Text("Display original text above the translation.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
