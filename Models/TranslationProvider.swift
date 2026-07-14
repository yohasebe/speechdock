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
        case .openAI: return "gpt-5.4-mini"
        case .gemini: return "gemini-3.1-flash-lite"
        case .grok: return "grok-4.20-non-reasoning"
        }
    }

    /// Available models for this provider
    var availableModels: [TranslationModelInfo] {
        switch self {
        case .macOS:
            return [TranslationModelInfo(id: "system", name: "System", isDefault: true)]
        case .openAI:
            return [
                TranslationModelInfo(id: "gpt-5.4-mini", name: "GPT-5.4 Mini", isDefault: true),
                TranslationModelInfo(id: "gpt-5.4-nano", name: "GPT-5.4 Nano", isDefault: false)
            ]
        case .gemini:
            // gemini-3.1-flash-lite-preview was shut down 2026-05-25; the GA id drops
            // the -preview suffix. gemini-3.1-pro-preview remains valid (no shutdown).
            return [
                TranslationModelInfo(id: "gemini-3.1-flash-lite", name: "Gemini 3.1 Flash Lite", isDefault: true),
                TranslationModelInfo(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro", isDefault: false)
            ]
        case .grok:
            // grok-4-1-fast-* retire 2026-08-15; replaced by the undated 4.20 aliases
            // (not the dated -0309 snapshots, which can themselves be retired).
            return [
                TranslationModelInfo(id: "grok-4.20-non-reasoning", name: "Grok 4.20 Fast", isDefault: true),
                TranslationModelInfo(id: "grok-4.20-reasoning", name: "Grok 4.20 Fast (Reasoning)", isDefault: false)
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
                return NSLocalizedString("On-device, ~18 languages", comment: "Translation provider description")
            } else {
                return NSLocalizedString("Requires macOS 26+", comment: "Translation provider description")
            }
        case .openAI:
            return NSLocalizedString("100+ languages, high quality", comment: "Translation provider description")
        case .gemini:
            return NSLocalizedString("100+ languages, high quality", comment: "Translation provider description")
        case .grok:
            return NSLocalizedString("100+ languages, high quality", comment: "Translation provider description")
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

    /// Get available translation languages for this provider (async, checks installed packs for macOS)
    func availableTranslationLanguages() async -> [LanguageCode] {
        if self == .macOS {
            return await MacOSTranslationAvailability.shared.getAvailableLanguages()
        }
        return LanguageCode.allCases.filter { $0 != .auto }
    }

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
