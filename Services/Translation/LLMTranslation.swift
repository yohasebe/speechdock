import Foundation
import NaturalLanguage

/// LLM-based translation service supporting OpenAI and Gemini
@MainActor
final class LLMTranslation: TranslationServiceProtocol {
    let provider: TranslationProvider
    private var currentTask: Task<TranslationResult, Error>?
    private let languageRecognizer = NLLanguageRecognizer()

    init(provider: TranslationProvider) {
        precondition(provider == .openAI || provider == .gemini, "LLMTranslation only supports OpenAI and Gemini")
        self.provider = provider
    }

    func translate(
        text: String,
        to targetLanguage: LanguageCode,
        from sourceLanguage: LanguageCode?
    ) async throws -> TranslationResult {
        #if DEBUG
        print("LLMTranslation.translate: provider=\(provider.displayName), target=\(targetLanguage.displayName)")
        #endif

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.noTextProvided
        }

        // Get API key
        guard let envKey = provider.envKeyName,
              let apiKey = APIKeyManager.shared.getAPIKey(for: envKey),
              !apiKey.isEmpty else {
            #if DEBUG
            print("LLMTranslation: No API key for \(provider.displayName)")
            #endif
            throw TranslationError.apiError("API key not configured for \(provider.displayName)")
        }

        #if DEBUG
        print("LLMTranslation: API key found, length=\(apiKey.count)")
        #endif

        // Detect source language to check for same-language translation
        if sourceLanguage == nil || sourceLanguage == .auto {
            if let detectedLanguage = detectLanguage(text),
               detectedLanguage == targetLanguage {
                let languageName = targetLanguage.displayName
                throw TranslationError.translationUnavailable(
                    "Text is already in \(languageName). Please select a different target language."
                )
            }
        } else if sourceLanguage == targetLanguage {
            let languageName = targetLanguage.displayName
            throw TranslationError.translationUnavailable(
                "Source and target languages are both \(languageName). Please select a different target language."
            )
        }

        currentTask = Task { [weak self] in
            guard let self = self else {
                throw TranslationError.cancelled
            }

            let translatedText: String
            switch self.provider {
            case .openAI:
                translatedText = try await self.translateWithOpenAI(
                    text: text,
                    targetLanguage: targetLanguage,
                    sourceLanguage: sourceLanguage,
                    apiKey: apiKey
                )
            case .gemini:
                translatedText = try await self.translateWithGemini(
                    text: text,
                    targetLanguage: targetLanguage,
                    sourceLanguage: sourceLanguage,
                    apiKey: apiKey
                )
            case .macOS:
                fatalError("LLMTranslation should not be used for macOS provider")
            }

            if Task.isCancelled {
                throw TranslationError.cancelled
            }

            return TranslationResult(
                originalText: text,
                translatedText: translatedText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                provider: self.provider
            )
        }

        return try await currentTask!.value
    }

    func isAvailable(from sourceLanguage: LanguageCode?, to targetLanguage: LanguageCode) async -> Bool {
        // LLM providers support all languages
        guard let envKey = provider.envKeyName,
              let apiKey = APIKeyManager.shared.getAPIKey(for: envKey),
              !apiKey.isEmpty else {
            return false
        }
        return true
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - OpenAI Translation

    private func translateWithOpenAI(
        text: String,
        targetLanguage: LanguageCode,
        sourceLanguage: LanguageCode?,
        apiKey: String
    ) async throws -> String {
        let endpoint = "https://api.openai.com/v1/chat/completions"
        let model = "gpt-4o-mini"

        let systemPrompt = buildTranslationPrompt(targetLanguage: targetLanguage, sourceLanguage: sourceLanguage)

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3
        ]

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 60

        #if DEBUG
        print("OpenAI Translation: Sending request...")
        #endif

        let (data, httpResponse) = try await TranslationAPIHelper.performRequest(request, providerName: "OpenAI")

        #if DEBUG
        print("OpenAI Translation: Response status = \(httpResponse.statusCode)")
        #endif

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranslationError.apiError("OpenAI API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            #if DEBUG
            print("OpenAI Translation: Invalid response format")
            print("OpenAI Translation: Raw response = \(String(data: data, encoding: .utf8) ?? "nil")")
            #endif
            throw TranslationError.apiError("Invalid response format from OpenAI")
        }

        #if DEBUG
        print("OpenAI Translation: Success, content length = \(content.count)")
        #endif

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Gemini Translation

    private func translateWithGemini(
        text: String,
        targetLanguage: LanguageCode,
        sourceLanguage: LanguageCode?,
        apiKey: String
    ) async throws -> String {
        // Use gemini-2.0-flash-001 for text generation (stable model)
        let model = "gemini-2.0-flash-001"
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"

        let systemPrompt = buildTranslationPrompt(targetLanguage: targetLanguage, sourceLanguage: sourceLanguage)

        let requestBody: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": "\(systemPrompt)\n\nText to translate:\n\(text)"]
                ]
            ]],
            "generationConfig": [
                "temperature": 0.3
            ]
        ]

        var urlComponents = URLComponents(string: endpoint)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 60

        #if DEBUG
        print("Gemini Translation: Sending request to \(endpoint)...")
        #endif

        let (data, httpResponse) = try await TranslationAPIHelper.performRequest(request, providerName: "Gemini")

        #if DEBUG
        print("Gemini Translation: Response status = \(httpResponse.statusCode)")
        #endif

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranslationError.apiError("Gemini API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let resultText = parts.first?["text"] as? String else {
            #if DEBUG
            print("Gemini Translation: Invalid response format")
            print("Gemini Translation: Raw response = \(String(data: data, encoding: .utf8) ?? "nil")")
            #endif
            throw TranslationError.apiError("Invalid response format from Gemini")
        }

        #if DEBUG
        print("Gemini Translation: Success, content length = \(resultText.count)")
        #endif

        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Translation Prompt

    private func buildTranslationPrompt(targetLanguage: LanguageCode, sourceLanguage: LanguageCode?) -> String {
        let targetName = englishLanguageName(for: targetLanguage)

        var prompt = """
        You are a professional translator. Translate the following text to \(targetName).
        Rules:
        - Preserve the original formatting and line breaks
        - Do not add explanations or notes
        - Output only the translated text
        """

        if let source = sourceLanguage, source != .auto {
            prompt += "\n- The source language is \(englishLanguageName(for: source))"
        }

        return prompt
    }

    /// Get English language name for clear LLM instructions
    private func englishLanguageName(for language: LanguageCode) -> String {
        switch language {
        case .auto: return "Auto"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .chinese: return "Chinese (Simplified Chinese)"
        case .korean: return "Korean"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .dutch: return "Dutch"
        case .polish: return "Polish"
        case .turkish: return "Turkish"
        case .indonesian: return "Indonesian"
        case .vietnamese: return "Vietnamese"
        case .thai: return "Thai"
        case .bengali: return "Bengali"
        case .gujarati: return "Gujarati"
        case .kannada: return "Kannada"
        case .malayalam: return "Malayalam"
        case .marathi: return "Marathi"
        case .tamil: return "Tamil"
        case .telugu: return "Telugu"
        }
    }

    // MARK: - Language Detection

    /// Detect the language of the given text
    private func detectLanguage(_ text: String) -> LanguageCode? {
        languageRecognizer.reset()
        languageRecognizer.processString(text)

        guard let nlLanguage = languageRecognizer.dominantLanguage else {
            return nil
        }

        // Map NLLanguage to LanguageCode
        return nlLanguageToLanguageCode(nlLanguage)
    }

    /// Convert NLLanguage to LanguageCode
    private func nlLanguageToLanguageCode(_ nlLanguage: NLLanguage) -> LanguageCode? {
        let mapping: [NLLanguage: LanguageCode] = [
            .english: .english,
            .japanese: .japanese,
            .simplifiedChinese: .chinese,
            .traditionalChinese: .chinese,
            .korean: .korean,
            .spanish: .spanish,
            .french: .french,
            .german: .german,
            .italian: .italian,
            .portuguese: .portuguese,
            .russian: .russian,
            .arabic: .arabic,
            .hindi: .hindi,
            .dutch: .dutch,
            .polish: .polish,
            .turkish: .turkish,
            .indonesian: .indonesian,
            .vietnamese: .vietnamese,
            .thai: .thai,
            .bengali: .bengali,
            .gujarati: .gujarati,
            .kannada: .kannada,
            .malayalam: .malayalam,
            .marathi: .marathi,
            .tamil: .tamil,
            .telugu: .telugu
        ]

        return mapping[nlLanguage]
    }
}
