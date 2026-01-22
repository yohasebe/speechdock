import Foundation

/// Translation service provider
enum TranslationProvider: String, CaseIterable, Identifiable, Codable {
    case macOS = "macOS"
    case openAI = "OpenAI"
    case gemini = "Gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    var envKeyName: String? {
        switch self {
        case .macOS: return nil  // No API key required
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        }
    }

    /// Whether this provider requires an API key
    var requiresAPIKey: Bool {
        envKeyName != nil
    }

    /// Whether this provider works offline
    var isOffline: Bool {
        self == .macOS
    }

    /// Model name used for translation
    var modelName: String {
        switch self {
        case .macOS: return "System"
        case .openAI: return "gpt-4o-mini"
        case .gemini: return "gemini-2.0-flash-001"
        }
    }

    /// Description for UI
    var description: String {
        switch self {
        case .macOS:
            if #available(macOS 26.0, *) {
                return "On-device, no API key"
            } else {
                return "Requires macOS 26+"
            }
        case .openAI:
            return "GPT-4o-mini, high quality"
        case .gemini:
            return "Gemini 2.0 Flash, high quality"
        }
    }

    /// Whether this provider is available on the current system
    var isAvailable: Bool {
        switch self {
        case .macOS:
            // macOS Translation requires macOS 26+ for direct TranslationSession API
            if #available(macOS 26.0, *) {
                return true
            }
            return false
        case .openAI, .gemini:
            // LLM providers are always available (API key check is separate)
            return true
        }
    }
}

// MARK: - Translation State

/// State of translation operation
enum TranslationState: Equatable {
    case idle                    // No translation (showing original)
    case translating             // Translation in progress
    case translated(String)      // Translation complete (holds translated text)
    case error(String)           // Error occurred

    var isTranslating: Bool {
        if case .translating = self { return true }
        return false
    }

    var isTranslated: Bool {
        if case .translated = self { return true }
        return false
    }

    var translatedText: String? {
        if case .translated(let text) = self { return text }
        return nil
    }
}

// MARK: - Language Support

extension TranslationProvider {
    /// Languages supported by macOS Translation framework
    /// Note: Actual availability depends on downloaded language packs
    static let macOSTranslationLanguages: [LanguageCode] = [
        .english, .japanese, .chinese, .korean,
        .spanish, .french, .german, .italian,
        .portuguese, .russian, .arabic,
        .dutch, .polish, .turkish,
        .indonesian, .vietnamese, .thai
    ]

    /// Get supported target languages for this provider
    func supportedTargetLanguages() -> [LanguageCode] {
        switch self {
        case .macOS:
            return TranslationProvider.macOSTranslationLanguages
        case .openAI, .gemini:
            // LLM providers support all languages in LanguageCode
            return LanguageCode.allCases.filter { $0 != .auto }
        }
    }

    /// Check if a specific language is supported
    func supportsLanguage(_ language: LanguageCode) -> Bool {
        supportedTargetLanguages().contains(language)
    }
}
