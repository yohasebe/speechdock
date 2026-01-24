import Foundation

/// Model information for translation providers
struct TranslationModelInfo: Identifiable {
    let id: String       // Model ID used in API calls
    let name: String     // Display name
    let isDefault: Bool  // Whether this is the default model for the provider
}

/// Translation service provider
enum TranslationProvider: String, CaseIterable, Identifiable, Codable {
    case macOS = "macOS"
    case openAI = "OpenAI"
    case gemini = "Gemini"
    case grok = "Grok"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        }
    }

    var envKeyName: String? {
        switch self {
        case .macOS: return nil  // No API key required
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .grok: return "GROK_API_KEY"
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

    /// Default model name used for translation
    var modelName: String {
        switch self {
        case .macOS: return "System"
        case .openAI: return "gpt-5-nano"
        case .gemini: return "gemini-3-flash-preview"
        case .grok: return "grok-3-fast"
        }
    }

    /// Available models for this provider
    var availableModels: [TranslationModelInfo] {
        switch self {
        case .macOS:
            return [TranslationModelInfo(id: "system", name: "System", isDefault: true)]
        case .openAI:
            return [
                TranslationModelInfo(id: "gpt-5-nano", name: "GPT-5 Nano", isDefault: true),
                TranslationModelInfo(id: "gpt-5-mini", name: "GPT-5 Mini", isDefault: false),
                TranslationModelInfo(id: "gpt-5.2", name: "GPT-5.2", isDefault: false)
            ]
        case .gemini:
            return [
                TranslationModelInfo(id: "gemini-3-flash-preview", name: "Gemini 3 Flash", isDefault: true),
                TranslationModelInfo(id: "gemini-3-pro-preview", name: "Gemini 3 Pro", isDefault: false)
            ]
        case .grok:
            return [
                TranslationModelInfo(id: "grok-3-fast", name: "Grok 3 Fast", isDefault: true),
                TranslationModelInfo(id: "grok-3-mini-fast", name: "Grok 3 Mini Fast", isDefault: false)
            ]
        }
    }

    /// Default model ID for this provider
    var defaultModelId: String {
        availableModels.first(where: { $0.isDefault })?.id ?? modelName
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
            return "GPT-5 Nano (default), high quality"
        case .gemini:
            return "Gemini 3 Flash (default), high quality"
        case .grok:
            return "Grok 3 Fast, high quality"
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
        case .openAI, .gemini, .grok:
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
        case .openAI, .gemini, .grok:
            // LLM providers support all languages in LanguageCode
            return LanguageCode.allCases.filter { $0 != .auto }
        }
    }

    /// Check if a specific language is supported
    func supportsLanguage(_ language: LanguageCode) -> Bool {
        supportedTargetLanguages().contains(language)
    }
}
