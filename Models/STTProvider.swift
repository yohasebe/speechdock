import Foundation

enum STTProvider: String, CaseIterable, Identifiable, Codable {
    case openAI = "OpenAI"
    case gemini = "Gemini"
    case elevenLabs = "ElevenLabs"

    var id: String { rawValue }

    var envKeyName: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .elevenLabs: return "ELEVENLABS_API_KEY"
        }
    }

    var availableModels: [STTModel] {
        switch self {
        case .openAI:
            return [.gpt4oMiniTranscribe, .gpt4oTranscribe, .whisper1]
        case .gemini:
            return [.gemini25Flash]
        case .elevenLabs:
            return [.scribeV1]
        }
    }

    var defaultModel: STTModel {
        availableModels.first!
    }
}

enum STTModel: String, CaseIterable, Identifiable, Codable {
    // OpenAI models
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe-2025-12-15"
    case whisper1 = "whisper-1"

    // Gemini models
    case gemini25Flash = "gemini-2.5-flash"

    // ElevenLabs models
    case scribeV1 = "scribe_v1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt4oTranscribe: return "GPT-4o Transcribe"
        case .gpt4oMiniTranscribe: return "GPT-4o Mini Transcribe"
        case .whisper1: return "Whisper-1"
        case .gemini25Flash: return "Gemini 2.5 Flash"
        case .scribeV1: return "Scribe v1"
        }
    }

    var provider: STTProvider {
        switch self {
        case .gpt4oTranscribe, .gpt4oMiniTranscribe, .whisper1:
            return .openAI
        case .gemini25Flash:
            return .gemini
        case .scribeV1:
            return .elevenLabs
        }
    }
}
