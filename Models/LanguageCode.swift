import Foundation
import Speech

/// Common language code definitions for STT and TTS services
enum LanguageCode: String, CaseIterable, Identifiable {
    case auto = ""
    case english = "en"
    case japanese = "ja"
    case chinese = "zh"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    // Additional languages for Gemini and other providers
    case dutch = "nl"
    case polish = "pl"
    case turkish = "tr"
    case indonesian = "id"
    case vietnamese = "vi"
    case thai = "th"
    case bengali = "bn"
    case gujarati = "gu"
    case kannada = "kn"
    case malayalam = "ml"
    case marathi = "mr"
    case tamil = "ta"
    case telugu = "te"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .english: return "English"
        case .japanese: return "日本語"
        case .chinese: return "中文"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .arabic: return "العربية"
        case .hindi: return "हिन्दी"
        case .dutch: return "Nederlands"
        case .polish: return "Polski"
        case .turkish: return "Türkçe"
        case .indonesian: return "Bahasa Indonesia"
        case .vietnamese: return "Tiếng Việt"
        case .thai: return "ไทย"
        case .bengali: return "বাংলা"
        case .gujarati: return "ગુજરાતી"
        case .kannada: return "ಕನ್ನಡ"
        case .malayalam: return "മലയാളം"
        case .marathi: return "मराठी"
        case .tamil: return "தமிழ்"
        case .telugu: return "తెలుగు"
        }
    }

    /// Convert to macOS Locale identifier (BCP-47 format)
    func toLocaleIdentifier() -> String? {
        guard self != .auto else { return nil }
        let mapping: [LanguageCode: String] = [
            .english: "en-US",
            .japanese: "ja-JP",
            .chinese: "zh-CN",
            .korean: "ko-KR",
            .spanish: "es-ES",
            .french: "fr-FR",
            .german: "de-DE",
            .italian: "it-IT",
            .portuguese: "pt-BR",
            .russian: "ru-RU",
            .arabic: "ar-SA",
            .hindi: "hi-IN",
            .dutch: "nl-NL",
            .polish: "pl-PL",
            .turkish: "tr-TR",
            .indonesian: "id-ID",
            .vietnamese: "vi-VN",
            .thai: "th-TH",
            .bengali: "bn-IN",
            .gujarati: "gu-IN",
            .kannada: "kn-IN",
            .malayalam: "ml-IN",
            .marathi: "mr-IN",
            .tamil: "ta-IN",
            .telugu: "te-IN"
        ]
        return mapping[self]
    }

    /// Convert to ElevenLabs TTS language code (ISO 639-2/3 format)
    func toElevenLabsTTSCode() -> String? {
        guard self != .auto else { return nil }
        let mapping: [LanguageCode: String] = [
            .english: "eng",
            .japanese: "jpn",
            .chinese: "cmn",
            .korean: "kor",
            .spanish: "spa",
            .french: "fra",
            .german: "deu",
            .italian: "ita",
            .portuguese: "por",
            .russian: "rus",
            .arabic: "ara",
            .hindi: "hin",
            .dutch: "nld",
            .polish: "pol",
            .turkish: "tur",
            .indonesian: "ind",
            .vietnamese: "vie",
            .thai: "tha",
            .bengali: "ben",
            .gujarati: "guj",
            .kannada: "kan",
            .malayalam: "mal",
            .marathi: "mar",
            .tamil: "tam",
            .telugu: "tel"
        ]
        return mapping[self]
    }
}

// MARK: - Provider-specific language support

extension LanguageCode {
    /// Common languages shown in the picker (curated subset)
    /// All providers support these via Auto detection even if not listed
    private static var commonLanguages: [LanguageCode] {
        [.auto, .english, .japanese, .chinese, .korean, .spanish, .french, .german,
         .italian, .portuguese, .russian, .arabic, .hindi, .dutch, .polish, .turkish,
         .indonesian, .vietnamese, .thai, .bengali, .gujarati, .kannada, .malayalam,
         .marathi, .tamil, .telugu]
    }

    /// Languages for Local Whisper, OpenAI, ElevenLabs (all support the same languages)
    static var whisperLanguages: [LanguageCode] { commonLanguages }
    static var openAILanguages: [LanguageCode] { commonLanguages }
    static var elevenLabsLanguages: [LanguageCode] { commonLanguages }

    /// Languages supported by Gemini Live API
    /// Note: Portuguese is NOT supported by Gemini
    static var geminiLanguages: [LanguageCode] {
        commonLanguages.filter { $0 != .portuguese }
    }

    /// Get supported languages for a given STT provider
    static func supportedLanguages(for provider: RealtimeSTTProvider) -> [LanguageCode] {
        switch provider {
        case .macOS:
            return macOSAvailableLanguages()
        case .localWhisper:
            return whisperLanguages
        case .openAI:
            return openAILanguages
        case .gemini:
            return geminiLanguages
        case .elevenLabs:
            return elevenLabsLanguages
        case .grok:
            return commonLanguages  // Grok supports 100+ languages with auto-detection
        }
    }

    /// Get available languages from macOS Speech Recognition
    /// Returns dynamically based on system-installed languages
    static func macOSAvailableLanguages() -> [LanguageCode] {
        let supportedLocales = SFSpeechRecognizer.supportedLocales()
        var availableLanguages: [LanguageCode] = []

        // Map system locales to our LanguageCode enum
        for locale in supportedLocales {
            let languageCode = locale.language.languageCode?.identifier ?? locale.identifier.prefix(2).lowercased()

            if let lang = LanguageCode(rawValue: String(languageCode.prefix(2))),
               !availableLanguages.contains(lang) {
                availableLanguages.append(lang)
            }
        }

        // Sort by display name, but keep a common order
        let preferredOrder: [LanguageCode] = [.english, .japanese, .chinese, .korean, .spanish, .french, .german, .italian, .portuguese, .russian, .arabic, .hindi]

        var sorted: [LanguageCode] = []
        for lang in preferredOrder {
            if availableLanguages.contains(lang) {
                sorted.append(lang)
            }
        }
        // Add any remaining languages
        for lang in availableLanguages where !sorted.contains(lang) {
            sorted.append(lang)
        }

        return sorted
    }

    /// Check if Auto detection is supported for a provider
    static func supportsAutoDetection(for provider: RealtimeSTTProvider) -> Bool {
        switch provider {
        case .macOS:
            return true  // Uses system locale when Auto is selected
        case .localWhisper, .openAI, .gemini, .elevenLabs, .grok:
            return true
        }
    }

    /// Get default language for a provider
    /// All providers currently support Auto detection
    static func defaultLanguage(for provider: RealtimeSTTProvider) -> LanguageCode {
        return .auto
    }
}
