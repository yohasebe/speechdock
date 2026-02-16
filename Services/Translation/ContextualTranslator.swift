import Foundation
import NaturalLanguage

// MARK: - Data Types

/// A confirmed sentence with its translation
struct TranslatedSentence: Equatable {
    let original: String
    let translated: String
}

/// Trigger that caused sentence confirmation
enum SentenceConfirmationTrigger {
    case tokenizer      // NLTokenizer detected sentence boundary
    case sttFinal       // STT final result signal
    case pauseTimeout   // No input for threshold duration
}

// MARK: - Protocol

/// Protocol for context-aware translation
@MainActor
protocol ContextualTranslator: AnyObject {
    /// The provider this translator represents
    var provider: TranslationProvider { get }

    /// Translate text with context from previous sentences
    /// - Parameters:
    ///   - text: Text to translate
    ///   - context: Previous sentences (original and translated pairs) for context
    ///   - targetLanguage: Target language for translation
    /// - Returns: Translated text
    func translate(
        text: String,
        context: [TranslatedSentence],
        to targetLanguage: LanguageCode
    ) async throws -> String

    /// Cancel any ongoing translation
    func cancel()
}

// MARK: - macOS Contextual Translator

#if compiler(>=6.1)
import Translation

@available(macOS 26.0, *)
@MainActor
final class MacOSContextualTranslator: ContextualTranslator {
    let provider: TranslationProvider = .macOS

    private var currentTask: Task<String, Error>?
    private let languageAvailability = LanguageAvailability()

    func translate(
        text: String,
        context: [TranslatedSentence],
        to targetLanguage: LanguageCode
    ) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }

        guard let targetLocale = targetLanguage.toLocaleLanguage() else {
            throw TranslationError.languageNotSupported(targetLanguage)
        }

        // Detect source language
        // If detection fails, try translation anyway (let the translation API handle it)
        let detectedLocale = detectSourceLanguage(trimmedText)

        // Skip only if we're confident it's the same language
        if let sourceLocale = detectedLocale,
           sourceLocale.languageCode == targetLocale.languageCode {
            dprint("MacOSTranslation: Skipping - same language detected (\(sourceLocale.languageCode?.identifier ?? "?"))")

            return trimmedText
        }

        // Use detected language or let Translation framework auto-detect
        let sourceLocale = detectedLocale ?? Locale.Language(identifier: "und")  // "und" = undetermined

        // Cancel previous task
        currentTask?.cancel()

        currentTask = Task { [weak self] in
            guard let self = self else { throw TranslationError.cancelled }

            // Determine actual source locale for session
            let actualSourceLocale: Locale.Language
            if sourceLocale.languageCode?.identifier == "und" {
                // Try to get a valid source locale by checking common languages
                // Default to a common source language that's likely installed
                let commonSources: [Locale.Language] = [
                    Locale.Language(identifier: "ja"),
                    Locale.Language(identifier: "en"),
                    Locale.Language(identifier: "zh-Hans"),
                    Locale.Language(identifier: "ko"),
                    Locale.Language(identifier: "es"),
                    Locale.Language(identifier: "fr"),
                    Locale.Language(identifier: "de")
                ]

                var foundSource: Locale.Language?
                for source in commonSources {
                    if source.languageCode == targetLocale.languageCode { continue }
                    let status = await self.languageAvailability.status(from: source, to: targetLocale)
                    if status == .installed {
                        foundSource = source
                        break
                    }
                }

                if let source = foundSource {
                    actualSourceLocale = source
                } else {
                    // Default to Japanese if translating to English, or English otherwise
                    actualSourceLocale = targetLocale.languageCode?.identifier == "en"
                        ? Locale.Language(identifier: "ja")
                        : Locale.Language(identifier: "en")
                }
                dprint("MacOSTranslation: Language detection failed, using \(actualSourceLocale.languageCode?.identifier ?? "?") as source")

            } else {
                actualSourceLocale = sourceLocale
            }

            // Check availability
            let status = await self.languageAvailability.status(from: actualSourceLocale, to: targetLocale)
            guard status == .installed else {
                throw TranslationError.translationUnavailable(
                    "Language pack not installed. Please check System Settings > Translation Languages."
                )
            }

            let session = TranslationSession(installedSource: actualSourceLocale, target: targetLocale)

            // macOS Translation API doesn't support context parameter
            // Direct translation is more reliable than context concatenation
            // which often results in mixed languages or extraction failures
            let response = try await session.translate(trimmedText)
            if Task.isCancelled { throw TranslationError.cancelled }
            return response.targetText
        }

        guard let task = currentTask else {
            throw TranslationError.apiError("Translation task failed to start")
        }
        return try await task.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Private Methods

    private func detectSourceLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let language = recognizer.dominantLanguage else { return nil }

        // Map NLLanguage to Locale.Language
        let mapping: [NLLanguage: String] = [
            .english: "en", .japanese: "ja", .simplifiedChinese: "zh-Hans",
            .traditionalChinese: "zh-Hant", .korean: "ko", .spanish: "es",
            .french: "fr", .german: "de", .italian: "it", .portuguese: "pt",
            .russian: "ru", .arabic: "ar", .hindi: "hi", .dutch: "nl",
            .polish: "pl", .turkish: "tr", .indonesian: "id",
            .vietnamese: "vi", .thai: "th"
        ]

        if let identifier = mapping[language] {
            return Locale.Language(identifier: identifier)
        }
        return Locale.Language(identifier: language.rawValue)
    }
}
#endif

// MARK: - LLM Contextual Translator (OpenAI, Gemini, Grok)

@MainActor
final class LLMContextualTranslator: ContextualTranslator {
    let provider: TranslationProvider

    private var currentTask: Task<String, Error>?
    private let model: String?

    init(provider: TranslationProvider, model: String? = nil) {
        self.provider = provider
        self.model = model
    }

    func translate(
        text: String,
        context: [TranslatedSentence],
        to targetLanguage: LanguageCode
    ) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }

        currentTask?.cancel()

        currentTask = Task { [weak self] in
            guard let self = self else { throw TranslationError.cancelled }

            let prompt = self.buildPrompt(
                text: trimmedText,
                context: context,
                targetLanguage: targetLanguage
            )

            let result: String
            switch self.provider {
            case .openAI:
                result = try await self.callOpenAI(prompt: prompt, targetLanguage: targetLanguage)
            case .gemini:
                result = try await self.callGemini(prompt: prompt, targetLanguage: targetLanguage)
            case .grok:
                result = try await self.callGrok(prompt: prompt, targetLanguage: targetLanguage)
            default:
                throw TranslationError.translationUnavailable("Unsupported provider: \(self.provider)")
            }

            if Task.isCancelled { throw TranslationError.cancelled }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let task = currentTask else {
            throw TranslationError.apiError("Translation task failed to start")
        }
        return try await task.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        text: String,
        context: [TranslatedSentence],
        targetLanguage: LanguageCode
    ) -> String {
        let contextPart: String
        if context.isEmpty {
            contextPart = "(No previous context)"
        } else {
            // Use last 2 sentences for context
            contextPart = context.suffix(2).map { pair in
                "\"\(pair.original)\" → \"\(pair.translated)\""
            }.joined(separator: "\n")
        }

        return """
        Translate the following text to \(targetLanguage.displayName).

        Previous context (for reference, to maintain consistency):
        \(contextPart)

        Text to translate:
        "\(text)"

        Rules:
        - Output ONLY the translation, nothing else
        - Maintain consistency with previous translations (terminology, style)
        - Use natural, conversational language
        - If the sentence is incomplete, translate naturally as possible
        """
    }

    // MARK: - API Calls

    private func callOpenAI(prompt: String, targetLanguage: LanguageCode) async throws -> String {
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: "OPENAI_API_KEY") else {
            throw TranslationError.apiError("OpenAI API key not found")
        }

        let modelId = model ?? provider.defaultModelId
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw TranslationError.apiError("Invalid OpenAI API endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // GPT-5 series uses reasoning_effort instead of temperature
        var body: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        if modelId.contains("gpt-5") {
            body["reasoning_effort"] = modelId == "gpt-5.2" ? "none" : "minimal"
        } else {
            body["temperature"] = 0.3
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await TranslationAPIHelper.performRequest(request, providerName: "OpenAI")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.apiError("Invalid OpenAI response format")
        }

        return content
    }

    private func callGemini(prompt: String, targetLanguage: LanguageCode) async throws -> String {
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: "GEMINI_API_KEY") else {
            throw TranslationError.apiError("Gemini API key not found")
        }

        let modelId = model ?? provider.defaultModelId
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):generateContent?key=\(apiKey)") else {
            throw TranslationError.apiError("Failed to construct Gemini API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.2
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await TranslationAPIHelper.performRequest(request, providerName: "Gemini")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw TranslationError.apiError("Invalid Gemini response format")
        }

        return text
    }

    private func callGrok(prompt: String, targetLanguage: LanguageCode) async throws -> String {
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: "GROK_API_KEY") else {
            throw TranslationError.apiError("Grok API key not found")
        }

        let modelId = model ?? provider.defaultModelId
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            throw TranslationError.apiError("Invalid Grok API endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": modelId,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await TranslationAPIHelper.performRequest(request, providerName: "Grok")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.apiError("Invalid Grok response format")
        }

        return content
    }
}

// MARK: - Factory

@MainActor
enum ContextualTranslatorFactory {
    static func makeTranslator(for provider: TranslationProvider, model: String? = nil) -> ContextualTranslator? {
        switch provider {
        case .macOS:
            #if compiler(>=6.1)
            if #available(macOS 26.0, *) {
                return MacOSContextualTranslator()
            }
            #endif
            return nil
        case .openAI, .gemini, .grok:
            return LLMContextualTranslator(provider: provider, model: model)
        }
    }
}

// MARK: - macOS Translation Language Availability

/// Service to check which languages are available for macOS translation
@MainActor
final class MacOSTranslationAvailability {
    static let shared = MacOSTranslationAvailability()

    /// Cache of available target languages (languages with installed packs)
    private var availableLanguagesCache: [LanguageCode]?
    private var lastCacheTime: Date?
    private let cacheValidityDuration: TimeInterval = 60  // 1 minute

    private init() {}

    /// Get list of languages available for translation (with installed language packs)
    /// - Parameter sourceHint: Optional hint for source language (affects availability)
    /// - Returns: Array of available target languages
    func getAvailableLanguages(sourceHint: String? = nil) async -> [LanguageCode] {
        // Check cache validity
        if let cached = availableLanguagesCache,
           let cacheTime = lastCacheTime,
           Date().timeIntervalSince(cacheTime) < cacheValidityDuration {
            return cached
        }

        #if compiler(>=6.1)
        if #available(macOS 26.0, *) {
            let availability = LanguageAvailability()

            // Common source languages to check against
            let sourcesToCheck: [Locale.Language] = [
                Locale.Language(identifier: sourceHint ?? "ja"),  // User's likely source
                Locale.Language(identifier: "en"),
                Locale.Language(identifier: "ja")
            ]

            var available: Set<LanguageCode> = []

            // Check each potential target language
            for targetLang in LanguageCode.allCases where targetLang != .auto {
                guard let targetLocale = targetLang.toLocaleLanguage() else { continue }

                // Check if any source -> target pair is installed
                for sourceLocale in sourcesToCheck {
                    if sourceLocale.languageCode == targetLocale.languageCode { continue }

                    let status = await availability.status(from: sourceLocale, to: targetLocale)
                    if status == .installed {
                        available.insert(targetLang)
                        break
                    }
                }
            }

            let result = Array(available).sorted { $0.displayName < $1.displayName }
            availableLanguagesCache = result
            lastCacheTime = Date()
            dprint("MacOSTranslationAvailability: Found \(result.count) installed languages: \(result.map { $0.rawValue })")


            return result
        }
        #endif

        // Fallback: return empty (macOS translation not available)
        return []
    }

    /// Check if a specific language is available
    func isLanguageAvailable(_ language: LanguageCode) async -> Bool {
        let available = await getAvailableLanguages()
        return available.contains(language)
    }

    /// Clear cache (call when user might have installed new language packs)
    func clearCache() {
        availableLanguagesCache = nil
        lastCacheTime = nil
    }
}
