import Foundation

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
            .hindi: "hi-IN"
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
            .hindi: "hin"
        ]
        return mapping[self]
    }
}
