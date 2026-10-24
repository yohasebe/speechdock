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
              let apiKey = await APIKeyManager.shared.apiKey(for: envKey),
              !apiKey.isEmpty else {
            dprint("LLMTranslation: No API key for \(provider.displayName)")

            throw TranslationError.apiError(APIKeyManager.shared.unavailableReason(for: provider.envKeyName ?? provider.displayName))
        }

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
        // Availability only: does not read a 1Password reference.
        guard let envKey = provider.envKeyName else { return false }
        return APIKeyManager.shared.hasAPIKey(for: envKey)
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

        requestBody.merge(Self.openAISamplingParameters(model: self.model)) { $1 }

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

        // Gemini 3.x models always think; use the lowest level the model accepts.
        // Translation doesn't benefit from chain-of-thought and the latency cost
        // is significant.
        let requestBody: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": "\(systemPrompt)\n\nText to translate:\n\(text)"]
                ]
            ]],
            "generationConfig": [
                "temperature": 0.3,
                "thinkingConfig": ["thinkingLevel": Self.geminiThinkingLevel(model: self.model)]
            ]
        ]

        guard let url = URL(string: endpoint) else {
            throw TranslationError.apiError("Invalid Gemini API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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

        // Parse response. Gemini 3.x can return multiple parts where some are thoughts
        // (`"thought": true`) and others are the actual answer. Skip thought parts and
        // concatenate any remaining text — `parts.first?["text"]` would otherwise return
        // the reasoning trace on Gemini 3.1 Pro (which always thinks).
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            dprint("Gemini Translation: Invalid response format")
            throw TranslationError.apiError("Invalid response format from Gemini")
        }

        let answerText = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !answerText.isEmpty else {
            dprint("Gemini Translation: No non-thought text parts in response")
            throw TranslationError.apiError("Invalid response format from Gemini")
        }
        dprint("Gemini Translation: Success, content length = \(answerText.count)")

        return answerText.trimmingCharacters(in: .whitespacesAndNewlines)
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

extension LLMTranslation {
    /// Reasoning models take `reasoning_effort` instead of `temperature`.
    /// GPT-6 Luna and GPT-5.x accept "none"; the original GPT-5 family's lowest is
    /// "minimal". Other GPT-6 models do not accept "none", so they get neither.
    nonisolated static func openAISamplingParameters(model: String) -> [String: Any] {
        if model.hasPrefix("gpt-6-luna") { return ["reasoning_effort": "none"] }
        if model.hasPrefix("gpt-6") { return [:] }
        if model.hasPrefix("gpt-5") { return ["reasoning_effort": model.contains("5.") ? "none" : "minimal"] }
        return ["temperature": 0.3]
    }

    /// The lowest thinking level the offered models accept: 3.1 Pro starts at "low",
    /// 3.5 Flash Lite at "minimal".
    nonisolated static func geminiThinkingLevel(model: String) -> String {
        model.contains("-pro") ? "low" : "minimal"
    }
}
