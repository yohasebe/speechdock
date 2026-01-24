import SwiftUI
import Translation

/// Translation controls for text areas in STT/TTS panels
/// Provides language selection, translation trigger, and revert functionality
struct TranslationControls: View {
    @Bindable var appState: AppState
    let text: String
    let onTranslate: (String) -> Void  // Callback when translation completes

    /// Available target languages for translation (excludes auto)
    private var availableLanguages: [LanguageCode] {
        LanguageCode.allCases.filter { $0 != .auto }
    }

    /// Whether translation controls should be shown
    private var shouldShowControls: Bool {
        // Don't show if text is empty or too short
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            return false
        }
        return true
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

    var body: some View {
        if shouldShowControls {
            HStack(spacing: 6) {
                if isTranslated {
                    // Show "Original" button when translated
                    originalButton
                } else if isTranslating {
                    // Show loading spinner
                    translatingIndicator
                } else {
                    // Show language selector
                    languageSelector
                }

                // Provider indicator (shows current provider)
                if !isTranslating {
                    providerIndicator

                    // Model selector (only for non-macOS providers)
                    if !isMacOSProvider {
                        modelIndicator
                    }
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
    }

    /// Language selector dropdown
    @ViewBuilder
    private var languageSelector: some View {
        Menu {
            ForEach(availableLanguages) { language in
                Button(action: {
                    handleLanguageSelection(language)
                }) {
                    HStack {
                        Text(language.displayName)

                        // Show availability indicator for macOS provider
                        // Uses AppState cache (0 = unsupported, 1 = needs download, 2 = installed)
                        if isMacOSProvider && appState.hasCachedMacOSTranslationLanguages {
                            if let status = languageStatus(language) {
                                switch status {
                                case 2: // installed
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                case 1: // supported (needs download)
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundColor(.orange)
                                case 0: // unsupported
                                    Image(systemName: "xmark.circle")
                                        .foregroundColor(.red)
                                default:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
                // Only disable if we've checked and it's unsupported (status == 0)
                .disabled(isMacOSProvider && appState.hasCachedMacOSTranslationLanguages && languageStatus(language) == 0)
            }

            // For macOS provider, add separator and options
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
                Image(systemName: "globe")
                    .font(.system(size: 12))
                Text("Translate")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .fixedSize()
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .help("Select a language to translate")
    }

    /// Button to revert to original text
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

    /// Translating indicator
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

    /// Provider indicator (text-based)
    @ViewBuilder
    private var providerIndicator: some View {
        let provider = effectiveProvider

        Menu {
            ForEach(TranslationProvider.allCases.filter { $0.isAvailable || hasAPIKey(for: $0) }) { p in
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
        .help("Translation provider: \(provider.displayName)")
    }

    /// Model selector (text-based menu for non-macOS providers)
    @ViewBuilder
    private var modelIndicator: some View {
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
        .help("Translation model: \(currentModel?.name ?? "")")
    }

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

    /// Handle language selection - either translate or request download
    private func handleLanguageSelection(_ language: LanguageCode) {
        // For macOS provider, check if language needs download
        if isMacOSProvider {
            if let status = languageStatus(language), status == 1 {
                // Language needs download - show alert with instructions
                showLanguageDownloadAlert(for: language)
                return
            }
        }

        // Otherwise, proceed with translation
        translateToLanguage(language)
    }

    /// Show alert for language pack download
    private func showLanguageDownloadAlert(for language: LanguageCode) {
        let alert = NSAlert()
        alert.messageText = "Language Pack Required"
        alert.informativeText = """
        The \(language.displayName) language pack needs to be downloaded.

        Please go to:
        System Settings → General → Language & Region → Translation Languages

        Then download "\(language.displayName)" and try again.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    /// Open System Settings app
    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Trigger translation to the specified language
    private func translateToLanguage(_ language: LanguageCode) {
        #if DEBUG
        print("TranslationControls: translateToLanguage called")
        print("TranslationControls: language = \(language.displayName)")
        print("TranslationControls: text length = \(text.count)")
        print("TranslationControls: text = \(text.prefix(50))...")
        #endif
        appState.translateText(text, to: language)
    }

    /// Revert to original text
    private func revertToOriginal() {
        appState.revertToOriginalText()
    }

    /// Show help for downloading language packs
    private func showDownloadLanguagesHelp() {
        let alert = NSAlert()
        alert.messageText = "Download Translation Languages"
        alert.informativeText = """
        To download language packs for offline translation:

        1. Open System Settings
        2. Go to General → Language & Region
        3. Scroll down to "Translation Languages"
        4. Download the languages you need

        After downloading, click "Refresh Status" to update the list.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // Idle state
        TranslationControls(
            appState: AppState.shared,
            text: "Hello, this is a test text for translation.",
            onTranslate: { _ in }
        )

        // Empty text (should be hidden)
        TranslationControls(
            appState: AppState.shared,
            text: "",
            onTranslate: { _ in }
        )
    }
    .padding()
    .frame(width: 400)
}
