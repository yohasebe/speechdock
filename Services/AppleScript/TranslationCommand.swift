import AppKit

// MARK: - Translate Command

class TranslateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            setAppleScriptError(.translationEmptyText, message: "Cannot translate empty text. Provide a non-empty string.")
            return nil
        }

        guard let languageName = evaluatedArguments?["toLanguage"] as? String, !languageName.isEmpty else {
            setAppleScriptError(.translationInvalidLanguage,
                message: "A target language is required. Use: translate \"text\" to \"Japanese\"")
            return nil
        }

        guard let targetLanguage = LanguageCode.fromName(languageName) else {
            let validNames = LanguageCode.allCases
                .filter { $0 != .auto }
                .map { $0.englishName }
                .joined(separator: ", ")
            setAppleScriptError(.translationInvalidLanguage,
                message: "Unknown language: \"\(languageName)\". Valid languages: \(validNames)")
            return nil
        }

        let (provider, model): (TranslationProvider, String?) = MainActor.assumeIsolated {
            let appState = AppState.shared
            let m = appState.selectedTranslationModel.isEmpty ? nil : appState.selectedTranslationModel
            return (appState.translationProvider, m)
        }

        if provider.requiresAPIKey {
            guard let envKeyName = provider.envKeyName,
                  APIKeyManager.shared.getAPIKey(for: envKeyName) != nil else {
                let envName = provider.envKeyName ?? "API_KEY"
                setAppleScriptError(.apiKeyNotConfigured,
                    message: "No API key configured for \(provider.rawValue) translation. Set the \(envName) environment variable or configure it in Settings.")
                return nil
            }
        }

        suspendExecution()

        Task { @MainActor in
            let translationService = TranslationFactory.makeService(for: provider, model: model)

            do {
                let result = try await translationService.translate(
                    text: text,
                    to: targetLanguage,
                    from: nil
                )
                self.resumeExecution(withResult: result.translatedText)
            } catch {
                self.setAppleScriptError(.translationFailed,
                    message: "Translation failed: \(error.localizedDescription)")
                self.resumeExecution(withResult: nil)
            }
        }

        return nil
    }
}
