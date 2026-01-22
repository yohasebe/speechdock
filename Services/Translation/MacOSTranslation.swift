import Foundation
import Translation
import NaturalLanguage

// MARK: - macOS 26+ Implementation

/// macOS native translation using the Translation framework
/// Direct TranslationSession initialization is available starting macOS 26.0
@available(macOS 26.0, *)
@MainActor
final class MacOSTranslation: TranslationServiceProtocol {
    let provider: TranslationProvider = .macOS

    private var currentTask: Task<TranslationResult, Error>?
    private let languageAvailability = LanguageAvailability()
    private let languageRecognizer = NLLanguageRecognizer()

    func translate(
        text: String,
        to targetLanguage: LanguageCode,
        from sourceLanguage: LanguageCode?
    ) async throws -> TranslationResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.noTextProvided
        }

        // Convert LanguageCode to Locale.Language
        guard let targetLocale = targetLanguage.toLocaleLanguage() else {
            throw TranslationError.languageNotSupported(targetLanguage)
        }

        // Detect source language first
        let sourceLocale: Locale.Language
        if let specifiedSource = sourceLanguage?.toLocaleLanguage() {
            sourceLocale = specifiedSource
        } else {
            // Auto-detect source language using NLLanguageRecognizer
            let detectedLanguage = detectLanguage(text)
            #if DEBUG
            print("MacOSTranslation: Detected source language = \(detectedLanguage?.rawValue ?? "unknown")")
            #endif

            if let detected = detectedLanguage,
               let detectedLocale = nlLanguageToLocale(detected) {
                // Don't translate if source and target are the same
                if detectedLocale.languageCode == targetLocale.languageCode {
                    let sourceName = Locale.current.localizedString(forLanguageCode: detectedLocale.languageCode?.identifier ?? "") ?? "Unknown"
                    throw TranslationError.translationUnavailable(
                        "Text is already in \(sourceName). Please select a different target language."
                    )
                }
                sourceLocale = detectedLocale
            } else {
                // Default to English if detection fails
                sourceLocale = Locale.Language(identifier: "en")
            }
        }

        #if DEBUG
        print("MacOSTranslation: Source = \(sourceLocale), Target = \(targetLocale)")
        #endif

        // Check availability for the actual language pair
        let status = await languageAvailability.status(
            from: sourceLocale,
            to: targetLocale
        )

        #if DEBUG
        print("MacOSTranslation: Language availability status = \(status)")
        #endif

        switch status {
        case .installed:
            #if DEBUG
            print("MacOSTranslation: Language pack is installed")
            #endif
        case .supported:
            // Language is supported but needs download
            #if DEBUG
            print("MacOSTranslation: Language pack needs to be downloaded")
            #endif
            throw TranslationError.translationUnavailable(
                "Language pack not installed. Please go to System Settings > General > Language & Region > Translation Languages to download the required language pack."
            )
        case .unsupported:
            throw TranslationError.languageNotSupported(targetLanguage)
        @unknown default:
            throw TranslationError.translationUnavailable("Unknown language status")
        }

        // Create translation task
        currentTask = Task { [weak self] in
            guard self != nil else {
                throw TranslationError.cancelled
            }

            #if DEBUG
            print("MacOSTranslation: Creating TranslationSession...")
            #endif

            // Use installedSource since we've verified the language is installed
            let session = TranslationSession(installedSource: sourceLocale, target: targetLocale)

            #if DEBUG
            print("MacOSTranslation: Translating text of length \(text.count)...")
            #endif

            do {
                let response = try await session.translate(text)

                if Task.isCancelled {
                    throw TranslationError.cancelled
                }

                #if DEBUG
                print("MacOSTranslation: Translation complete, result length = \(response.targetText.count)")
                #endif

                return TranslationResult(
                    originalText: text,
                    translatedText: response.targetText,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    provider: .macOS
                )
            } catch let error as TranslationError {
                throw error
            } catch {
                // Handle Translation framework specific errors
                let errorDescription = error.localizedDescription

                #if DEBUG
                print("MacOSTranslation: Translation error = \(error)")
                #endif

                // Check for language pack errors
                let errorString = String(describing: error)
                if errorDescription.contains("download") ||
                   errorString.contains("TranslationErrorDomain") ||
                   errorString.contains("Code=16") ||
                   errorString.contains("Code=2") {
                    throw TranslationError.translationUnavailable(
                        "Language pack not available. Please go to System Settings > General > Language & Region > Translation Languages."
                    )
                }

                throw TranslationError.apiError(errorDescription)
            }
        }

        return try await currentTask!.value
    }

    func isAvailable(from sourceLanguage: LanguageCode?, to targetLanguage: LanguageCode) async -> Bool {
        guard let targetLocale = targetLanguage.toLocaleLanguage() else {
            return false
        }

        let sourceLocale = sourceLanguage?.toLocaleLanguage() ?? Locale.Language(identifier: "en")
        let status = await languageAvailability.status(from: sourceLocale, to: targetLocale)

        switch status {
        case .installed, .supported:
            return true
        case .unsupported:
            return false
        @unknown default:
            return false
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Language Detection

    /// Detect the language of the given text using NLLanguageRecognizer
    private func detectLanguage(_ text: String) -> NLLanguage? {
        languageRecognizer.reset()
        languageRecognizer.processString(text)
        return languageRecognizer.dominantLanguage
    }

    /// Convert NLLanguage to Locale.Language
    private func nlLanguageToLocale(_ nlLanguage: NLLanguage) -> Locale.Language? {
        // Map NLLanguage to BCP 47 identifiers
        let mapping: [NLLanguage: String] = [
            .english: "en",
            .japanese: "ja",
            .simplifiedChinese: "zh-Hans",
            .traditionalChinese: "zh-Hant",
            .korean: "ko",
            .spanish: "es",
            .french: "fr",
            .german: "de",
            .italian: "it",
            .portuguese: "pt",
            .russian: "ru",
            .arabic: "ar",
            .hindi: "hi",
            .dutch: "nl",
            .polish: "pl",
            .turkish: "tr",
            .indonesian: "id",
            .vietnamese: "vi",
            .thai: "th"
        ]

        guard let identifier = mapping[nlLanguage] else {
            // Try using the raw value as identifier
            return Locale.Language(identifier: nlLanguage.rawValue)
        }

        return Locale.Language(identifier: identifier)
    }
}

// MARK: - Fallback for older macOS versions

/// Fallback translation for systems where macOS Translation is not directly available (< macOS 26)
/// Returns an error suggesting the user use LLM translation instead
@MainActor
final class MacOSTranslationFallback: TranslationServiceProtocol {
    let provider: TranslationProvider = .macOS

    func translate(
        text: String,
        to targetLanguage: LanguageCode,
        from sourceLanguage: LanguageCode?
    ) async throws -> TranslationResult {
        throw TranslationError.translationUnavailable(
            "macOS Translation requires macOS 26.0 or later. Please use OpenAI or Gemini for translation."
        )
    }

    func isAvailable(from sourceLanguage: LanguageCode?, to targetLanguage: LanguageCode) async -> Bool {
        return false
    }

    func cancel() {
        // No-op
    }
}

// MARK: - LanguageCode Extension for Translation

extension LanguageCode {
    /// Convert to Locale.Language for Translation framework
    func toLocaleLanguage() -> Locale.Language? {
        guard self != .auto else { return nil }

        // Map LanguageCode to BCP 47 language tags that Translation framework accepts
        let mapping: [LanguageCode: String] = [
            .english: "en",
            .japanese: "ja",
            .chinese: "zh-Hans",  // Simplified Chinese
            .korean: "ko",
            .spanish: "es",
            .french: "fr",
            .german: "de",
            .italian: "it",
            .portuguese: "pt",
            .russian: "ru",
            .arabic: "ar",
            .hindi: "hi",
            .dutch: "nl",
            .polish: "pl",
            .turkish: "tr",
            .indonesian: "id",
            .vietnamese: "vi",
            .thai: "th",
            .bengali: "bn",
            .gujarati: "gu",
            .kannada: "kn",
            .malayalam: "ml",
            .marathi: "mr",
            .tamil: "ta",
            .telugu: "te"
        ]

        guard let identifier = mapping[self] else {
            return nil
        }

        return Locale.Language(identifier: identifier)
    }
}
