import Foundation

/// Error types for translation services
enum TranslationError: LocalizedError {
    case apiError(String)
    case networkError(String)
    case noTextProvided
    case languageNotSupported(LanguageCode)
    case translationUnavailable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .apiError(let message):
            return "API Error: \(message)"
        case .networkError(let message):
            return "Network Error: \(message)"
        case .noTextProvided:
            return "No text provided for translation"
        case .languageNotSupported(let language):
            return "Language not supported: \(language.displayName)"
        case .translationUnavailable(let reason):
            return "Translation unavailable: \(reason)"
        case .cancelled:
            return "Translation cancelled"
        }
    }
}

/// Translation result
struct TranslationResult {
    let originalText: String
    let translatedText: String
    let sourceLanguage: LanguageCode?
    let targetLanguage: LanguageCode
    let provider: TranslationProvider
}

/// Protocol for translation services
@MainActor
protocol TranslationServiceProtocol: AnyObject {
    /// The provider this service represents
    var provider: TranslationProvider { get }

    /// Translate text to target language
    /// - Parameters:
    ///   - text: The text to translate
    ///   - targetLanguage: The language to translate to
    ///   - sourceLanguage: Optional source language (nil for auto-detect)
    /// - Returns: TranslationResult containing original and translated text
    func translate(
        text: String,
        to targetLanguage: LanguageCode,
        from sourceLanguage: LanguageCode?
    ) async throws -> TranslationResult

    /// Check if translation to/from a language pair is available
    /// - Parameters:
    ///   - sourceLanguage: Source language (nil for auto-detect)
    ///   - targetLanguage: Target language
    /// - Returns: true if translation is available
    func isAvailable(from sourceLanguage: LanguageCode?, to targetLanguage: LanguageCode) async -> Bool

    /// Cancel any ongoing translation
    func cancel()
}

/// Factory for creating translation services
@MainActor
enum TranslationFactory {
    static func makeService(for provider: TranslationProvider) -> TranslationServiceProtocol {
        switch provider {
        case .macOS:
            // macOS Translation direct API is available starting macOS 26
            #if compiler(>=6.1)
            if #available(macOS 26.0, *) {
                return MacOSTranslation()
            } else {
                return MacOSTranslationFallback()
            }
            #else
            return MacOSTranslationFallback()
            #endif
        case .openAI:
            return LLMTranslation(provider: .openAI)
        case .gemini:
            return LLMTranslation(provider: .gemini)
        }
    }

    /// Check if macOS native translation is available (requires macOS 26+)
    static var isMacOSTranslationAvailable: Bool {
        #if compiler(>=6.1)
        if #available(macOS 26.0, *) {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Get the best available translation provider based on target language and API key availability
    /// - Parameters:
    ///   - targetLanguage: The language to translate to
    ///   - preferredProvider: User's preferred provider (if any)
    /// - Returns: The best available provider
    static func bestAvailableProvider(
        for targetLanguage: LanguageCode,
        preferredProvider: TranslationProvider?
    ) -> TranslationProvider {
        // If user has a preference and it supports the language, use it
        if let preferred = preferredProvider,
           preferred.supportsLanguage(targetLanguage) {
            // Check API key availability for LLM providers
            if preferred.requiresAPIKey {
                let apiKey = APIKeyManager.shared.getAPIKey(for: preferred.envKeyName!)
                if apiKey != nil && !apiKey!.isEmpty {
                    return preferred
                }
            } else {
                return preferred
            }
        }

        // Fallback: Check providers in priority order
        // 1. macOS Translation (no API key, on-device, requires macOS 26+)
        if isMacOSTranslationAvailable && TranslationProvider.macOS.supportsLanguage(targetLanguage) {
            return .macOS
        }

        // 2. OpenAI (if API key available)
        if let apiKey = APIKeyManager.shared.getAPIKey(for: "OPENAI_API_KEY"),
           !apiKey.isEmpty {
            return .openAI
        }

        // 3. Gemini (if API key available)
        if let apiKey = APIKeyManager.shared.getAPIKey(for: "GEMINI_API_KEY"),
           !apiKey.isEmpty {
            return .gemini
        }

        // Default to macOS (will show error if language not supported)
        return .macOS
    }
}

// MARK: - API Retry Helper

/// Helper for translation API requests with retry logic
enum TranslationAPIHelper {
    private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
    private static let maxRetries = 3

    /// Perform an API request with automatic retry for transient errors
    static func performRequest(_ request: URLRequest, providerName: String) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        var lastStatusCode: Int?
        var lastResponseBody: String?

        for attempt in 0..<maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranslationError.networkError("Invalid response")
                }

                if httpResponse.statusCode == 200 {
                    return (data, httpResponse)
                }

                if retryableStatusCodes.contains(httpResponse.statusCode) {
                    lastStatusCode = httpResponse.statusCode
                    lastResponseBody = String(data: data, encoding: .utf8)

                    if attempt < maxRetries - 1 {
                        let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                        try await Task.sleep(nanoseconds: delay)
                        #if DEBUG
                        print("\(providerName) Translation: Retry \(attempt + 1)/\(maxRetries) after HTTP \(httpResponse.statusCode)")
                        #endif
                        continue
                    }
                }

                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw TranslationError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")

            } catch let error as TranslationError {
                throw error
            } catch {
                lastError = error

                if attempt < maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
            }
        }

        if let statusCode = lastStatusCode {
            let userMessage: String
            switch statusCode {
            case 429:
                userMessage = "Rate limit exceeded. Please wait and try again."
            case 503:
                userMessage = "Service temporarily unavailable."
            default:
                userMessage = "HTTP \(statusCode): \(lastResponseBody ?? "Unknown error")"
            }
            throw TranslationError.apiError(userMessage)
        }

        if let error = lastError {
            throw TranslationError.networkError(error.localizedDescription)
        }

        throw TranslationError.networkError("Request failed after \(maxRetries) attempts")
    }
}
