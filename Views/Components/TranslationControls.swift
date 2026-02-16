import SwiftUI

/// Translation controls for text areas in STT/TTS panels
/// Provides separate language selection and translation execution
struct TranslationControls: View {
    @Bindable var appState: AppState
    let text: String
    let onTranslate: (String) -> Void  // Callback when translation completes

    /// Available target languages for translation (excludes auto)
    /// For macOS provider, only show installed languages
    private var availableLanguages: [LanguageCode] {
        let allLanguages = LanguageCode.allCases.filter { $0 != .auto }

        // For macOS provider with cached data, only show installed languages
        if isMacOSProvider && appState.hasCachedMacOSTranslationLanguages {
            return allLanguages.filter { language in
                languageStatus(language) == 2  // 2 = installed
            }
        }

        return allLanguages
    }

    /// Whether we have enough text to translate
    private var hasEnoughText: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    /// Whether translation is in progress
    private var isTranslating: Bool {
        appState.translationState.isTranslating
    }

    /// Whether showing translated text
    private var isTranslated: Bool {
        appState.translationState.isTranslated
    }

    /// Whether using macOS provider
    private var isMacOSProvider: Bool {
        appState.translationProvider == .macOS
    }

    /// Get language availability status from AppState cache
    private func languageStatus(_ language: LanguageCode) -> Int? {
        appState.macOSTranslationLanguageCache[language]
    }

    /// Whether the current target language is available for the selected provider
    private var isTargetLanguageAvailable: Bool {
        // For non-macOS providers, all languages are available
        guard isMacOSProvider else { return true }

        // For macOS, check if language is installed (status == 2)
        // If no cache yet, assume available (will be validated when translation runs)
        guard appState.hasCachedMacOSTranslationLanguages else { return true }

        return languageStatus(appState.translationTargetLanguage) == 2
    }

    /// Whether translation can be executed
    private var canTranslate: Bool {
        hasEnoughText && isTargetLanguageAvailable
    }

    /// Whether settings can be changed (disabled during translation)
    private var canChangeSettings: Bool {
        !isTranslating
    }

    var body: some View {
        HStack(spacing: 6) {
            // Translate/Original/Translating button
            if isTranslated {
                originalButton
            } else if isTranslating {
                translatingIndicator
            } else {
                translateButton
            }

            // Language selector (always visible, separate from translate action)
            languageSelector

            // Provider selector
            providerSelector

            // Model selector (only for non-macOS providers)
            if !isMacOSProvider {
                modelSelector
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .background(Color(.windowBackgroundColor).opacity(0.9))
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        .fixedSize(horizontal: true, vertical: false)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check availability when app becomes active (after returning from System Settings)
            if isMacOSProvider {
                appState.refreshMacOSTranslationLanguageAvailability()
            }
        }
    }

    // MARK: - Translate Button

    @ViewBuilder
    private var translateButton: some View {
        Button(action: {
            executeTranslation()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                Text("Translate")
                    .font(.system(size: 11, weight: .medium))
            }
            .fixedSize()
            .foregroundColor(canTranslate ? .secondary : .secondary.opacity(0.4))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(canTranslate ? 0.1 : 0.05))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(!canTranslate)
        .help(translateButtonHelpText)
    }

    /// Help text for translate button based on current state
    private var translateButtonHelpText: String {
        if !hasEnoughText {
            return "Enter text to enable translation"
        }
        if !isTargetLanguageAvailable {
            return "Select a target language"
        }
        return "Translate to \(appState.translationTargetLanguage.displayName)"
    }

    // MARK: - Original Button

    @ViewBuilder
    private var originalButton: some View {
        Button(action: {
            revertToOriginal()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                Text("Original")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .semibold))
            }
            .fixedSize()
            .foregroundColor(.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help("Revert to original text")
    }

    // MARK: - Translating Indicator

    @ViewBuilder
    private var translatingIndicator: some View {
        Button(action: {
            appState.cancelTranslation()
        }) {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Translating...")
                    .font(.system(size: 11))
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help("Cancel translation")
    }

    // MARK: - Language Selector (selection only, no translation)

    /// Display name for current target language with fallback
    private var targetLanguageDisplayName: String {
        // Show "Select..." if language is not available for current provider
        if !isTargetLanguageAvailable {
            return "Select..."
        }
        let name = appState.translationTargetLanguage.displayName
        return name.isEmpty ? "Select..." : name
    }

    @ViewBuilder
    private var languageSelector: some View {
        Menu {
            ForEach(availableLanguages) { language in
                Button(action: {
                    selectLanguage(language)
                }) {
                    HStack {
                        Text(language.displayName)
                        if language == appState.translationTargetLanguage {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            // For macOS provider, add separator and download options
            if isMacOSProvider {
                Divider()

                Button(action: {
                    showDownloadLanguagesHelp()
                }) {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Download Languages...")
                    }
                }

                Button(action: {
                    appState.refreshMacOSTranslationLanguageAvailability()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh Status")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("→ \(targetLanguageDisplayName)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!canChangeSettings)
        .opacity(canChangeSettings ? 1.0 : 0.5)
        .help(canChangeSettings ? "Target language: \(targetLanguageDisplayName)" : "Cannot change during translation")
    }

    // MARK: - Provider Selector

    @ViewBuilder
    private var providerSelector: some View {
        let provider = effectiveProvider

        Menu {
            ForEach(TranslationProvider.allCases.filter { isProviderAvailable($0) }) { p in
                Button(action: {
                    // Revert to original if currently showing translation
                    if appState.translationState.isTranslated {
                        appState.revertToOriginalText()
                    }
                    appState.translationProvider = p
                }) {
                    HStack {
                        Text(p.displayName)
                        Text("(\(p.description))")
                            .foregroundColor(.secondary)
                        if p == appState.translationProvider {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!hasAPIKey(for: p) && p.requiresAPIKey)
            }
        } label: {
            Text(provider.displayName)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .disabled(!canChangeSettings)
        .opacity(canChangeSettings ? 1.0 : 0.5)
        .help(canChangeSettings ? "Translation provider: \(provider.displayName)" : "Cannot change during translation")
    }

    // MARK: - Model Selector

    @ViewBuilder
    private var modelSelector: some View {
        let models = appState.translationProvider.availableModels
        let currentModel = models.first(where: { $0.id == appState.selectedTranslationModel })
            ?? models.first(where: { $0.isDefault })

        Menu {
            ForEach(models) { model in
                Button(action: {
                    appState.selectedTranslationModel = model.id
                }) {
                    HStack {
                        Text(model.name)
                        if model.id == appState.selectedTranslationModel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(currentModel?.name ?? "")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .disabled(!canChangeSettings)
        .opacity(canChangeSettings ? 1.0 : 0.5)
        .help(canChangeSettings ? "Translation model: \(currentModel?.name ?? "")" : "Cannot change during translation")
    }

    // MARK: - Helper Properties

    /// Get the effective provider (considering API key availability)
    private var effectiveProvider: TranslationProvider {
        TranslationFactory.bestAvailableProvider(
            for: appState.translationTargetLanguage,
            preferredProvider: appState.translationProvider
        )
    }

    /// Check if API key is available for a provider
    private func hasAPIKey(for provider: TranslationProvider) -> Bool {
        guard let envKey = provider.envKeyName else { return true }
        return APIKeyManager.shared.getAPIKey(for: envKey) != nil
    }

    /// Check if provider is available (OS support + API key)
    private func isProviderAvailable(_ provider: TranslationProvider) -> Bool {
        // macOS provider requires macOS 26+ for Translation framework
        if provider == .macOS {
            #if compiler(>=6.1)
            if #available(macOS 26.0, *) {
                return true
            }
            #endif
            return false
        }
        return provider.isAvailable || hasAPIKey(for: provider)
    }

    // MARK: - Actions

    /// Select target language (does NOT trigger translation)
    private func selectLanguage(_ language: LanguageCode) {
        // For macOS provider, check if language needs download
        if isMacOSProvider {
            if let status = languageStatus(language), status == 1 {
                // Language needs download - show alert with instructions
                showLanguageDownloadAlert(for: language)
                return
            }
        }

        // Revert to original if currently showing translation (same as provider change)
        if appState.translationState.isTranslated {
            appState.revertToOriginalText()
        }

        // Update the selected language
        appState.translationTargetLanguage = language
    }

    /// Execute translation to the currently selected language
    private func executeTranslation() {
        guard hasEnoughText else { return }
        dprint("TranslationControls: executeTranslation called")
        dprint("TranslationControls: language = \(appState.translationTargetLanguage.displayName)")
        dprint("TranslationControls: text length = \(text.count)")


        appState.translateText(text, to: appState.translationTargetLanguage)
    }

    /// Revert to original text
    private func revertToOriginal() {
        appState.revertToOriginalText()
    }

    /// Show alert for language pack download
    private func showLanguageDownloadAlert(for language: LanguageCode) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Language Pack Required", comment: "Language download alert title")
        alert.informativeText = String(format: NSLocalizedString("The %@ language pack needs to be downloaded.\n\nPlease go to:\nSystem Settings → General → Language & Region → Translation Languages\n\nThen download \"%@\" and try again.", comment: "Language download alert message"), language.displayName, language.displayName)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: "Open system settings button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    /// Open System Settings app
    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Show help for downloading language packs
    private func showDownloadLanguagesHelp() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Download Translation Languages", comment: "Download languages help title")
        alert.informativeText = NSLocalizedString("To download language packs for offline translation:\n\n1. Open System Settings\n2. Go to General → Language & Region\n3. Scroll down to \"Translation Languages\"\n4. Download the languages you need\n\nAfter downloading, click \"Refresh Status\" to update the list.", comment: "Download languages help message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: "Open system settings button"))
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // With text
        TranslationControls(
            appState: AppState.shared,
            text: "Hello, this is a test text for translation.",
            onTranslate: { _ in }
        )

        // Empty text
        TranslationControls(
            appState: AppState.shared,
            text: "",
            onTranslate: { _ in }
        )
    }
    .padding()
    .frame(width: 500)
}
