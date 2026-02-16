import Foundation
import NaturalLanguage

/// LLM-based translation service supporting OpenAI, Gemini, and Grok
@MainActor
final class LLMTranslation: TranslationServiceProtocol {
    let provider: TranslationProvider
    let model: String
    private var currentTask: Task<TranslationResult, Error>?
    private let languageRecognizer = NLLanguageRecognizer()

    init(provider: TranslationProvider, model: String? = nil) {
        assert(provider == .openAI || provider == .gemini || provider == .grok, "LLMTranslation only supports OpenAI, Gemini, and Grok")
        self.provider = provider
        self.model = model ?? provider.defaultModelId
    }

    func translate(
        text: String,
        to targetLanguage: LanguageCode,
        from sourceLanguage: LanguageCode?
    ) async throws -> TranslationResult {
        dprint("LLMTranslation.translate: provider=\(provider.displayName), target=\(targetLanguage.displayName)")


        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.noTextProvided
        }

        // Get API key
        guard let envKey = provider.envKeyName,
              let apiKey = APIKeyManager.shared.getAPIKey(for: envKey),
              !apiKey.isEmpty else {
            dprint("LLMTranslation: No API key for \(provider.displayName)")

            throw TranslationError.apiError("API key not configured for \(provider.displayName)")
        }
        dprint("LLMTranslation: API key found, length=\(apiKey.count)")


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

        // Cancel any existing task (defensive)
        currentTask?.cancel()

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
            case .grok:
                translatedText = try await self.translateWithGrok(
                    text: text,
                    targetLanguage: targetLanguage,
                    sourceLanguage: sourceLanguage,
                    apiKey: apiKey
                )
            case .macOS:
                throw TranslationError.translationUnavailable("LLMTranslation does not support macOS provider. Use MacOSTranslation instead.")
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

        guard let task = currentTask else {
            throw TranslationError.apiError("Translation task failed to start")
        }
        return try await task.value
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

        let systemPrompt = buildTranslationPrompt(targetLanguage: targetLanguage, sourceLanguage: sourceLanguage)

        var requestBody: [String: Any] = [
            "model": self.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        if self.model.hasPrefix("gpt-5") {
            // GPT-5 family: no temperature support, use reasoning_effort instead
            // gpt-5.2: supports "none" (default is already "none")
            // gpt-5, gpt-5-mini, gpt-5-nano: lowest is "minimal"
            if self.model.contains("5.") {
                // gpt-5.1, gpt-5.2 etc. support "none"
                requestBody["reasoning_effort"] = "none"
            } else {
                // gpt-5, gpt-5-mini, gpt-5-nano: lowest is "minimal"
                requestBody["reasoning_effort"] = "minimal"
            }
        } else {
            requestBody["temperature"] = 0.3
        }

        guard let url = URL(string: endpoint) else {
            throw TranslationError.apiError("Invalid OpenAI API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 60
        dprint("OpenAI Translation: Sending request with model=\(self.model)...")


        let (data, httpResponse) = try await TranslationAPIHelper.performRequest(request, providerName: "OpenAI")
        dprint("OpenAI Translation: Response status = \(httpResponse.statusCode)")


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
            dprint("OpenAI Translation: Invalid response format")
            dprint("OpenAI Translation: Raw response = \(String(data: data, encoding: .utf8) ?? "nil")")

            throw TranslationError.apiError("Invalid response format from OpenAI")
        }
        dprint("OpenAI Translation: Success, content length = \(content.count)")


        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Gemini Translation

    private func translateWithGemini(
        text: String,
        targetLanguage: LanguageCode,
        sourceLanguage: LanguageCode?,
        apiKey: String
    ) async throws -> String {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(self.model):generateContent"

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

        guard var urlComponents = URLComponents(string: endpoint) else {
            throw TranslationError.apiError("Invalid Gemini API endpoint URL")
        }
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = urlComponents.url else {
            throw TranslationError.apiError("Failed to construct Gemini API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 60
        dprint("Gemini Translation: Sending request with model=\(self.model)...")


        let (data, httpResponse) = try await TranslationAPIHelper.performRequest(request, providerName: "Gemini")
        dprint("Gemini Translation: Response status = \(httpResponse.statusCode)")


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
            dprint("Gemini Translation: Invalid response format")
            dprint("Gemini Translation: Raw response = \(String(data: data, encoding: .utf8) ?? "nil")")

            throw TranslationError.apiError("Invalid response format from Gemini")
        }
        dprint("Gemini Translation: Success, content length = \(resultText.count)")


        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Grok Translation

    private func translateWithGrok(
        text: String,
        targetLanguage: LanguageCode,
        sourceLanguage: LanguageCode?,
        apiKey: String
    ) async throws -> String {
        // Grok uses OpenAI-compatible API format
        let endpoint = "https://api.x.ai/v1/chat/completions"

        let systemPrompt = buildTranslationPrompt(targetLanguage: targetLanguage, sourceLanguage: sourceLanguage)

        let requestBody: [String: Any] = [
            "model": self.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.3
        ]

        guard let url = URL(string: endpoint) else {
            throw TranslationError.apiError("Invalid Grok API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 60
        dprint("Grok Translation: Sending request with model=\(self.model)...")


        let (data, httpResponse) = try await TranslationAPIHelper.performRequest(request, providerName: "Grok")
        dprint("Grok Translation: Response status = \(httpResponse.statusCode)")


        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranslationError.apiError("Grok API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        // Parse response (OpenAI-compatible format)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            dprint("Grok Translation: Invalid response format")
            dprint("Grok Translation: Raw response = \(String(data: data, encoding: .utf8) ?? "nil")")

            throw TranslationError.apiError("Invalid response format from Grok")
        }
        dprint("Grok Translation: Success, content length = \(content.count)")


        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
