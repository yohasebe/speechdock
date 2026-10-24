import Foundation

enum STTProvider: String, CaseIterable, Identifiable, Codable {
    case openAI = "OpenAI"
    case gemini = "Gemini"
    case elevenLabs = "ElevenLabs"
    case grok = "Grok"

    var id: String { rawValue }

    var envKeyName: String {
        switch self {
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .elevenLabs: return "ELEVENLABS_API_KEY"
        case .grok: return "XAI_API_KEY"  // GROK_API_KEY is still read (APIKeyManager.keyNameAliases)
        }
    }

    var availableModels: [STTModel] {
        switch self {
        case .openAI:
            return [.gptTranscribe]
        case .gemini:
            return [.gemini38Flash]
        case .elevenLabs:
            return [.scribeV2]
        case .grok:
            return [.grokSTT]
        }
    }

    var defaultModel: STTModel {
        // Each provider always has at least one model defined in availableModels
        guard let model = availableModels.first else {
            // Fallback that should never be reached
            return .gptTranscribe
        }
        return model
    }

    var footerDescription: String {
        switch self {
        case .openAI:
            return "Enables STT (GPT Realtime Whisper, GPT Live Transcribe, GPT Transcribe), TTS (GPT-4o Mini TTS), and translation. Optional — macOS built-in works without this."
        case .gemini:
            return "Enables STT (Gemini Live, Gemini 3.8 Flash), TTS (Gemini 3.8 Flash / Flash-Lite TTS), and translation. Optional — macOS built-in works without this."
        case .elevenLabs:
            return "Enables STT (Scribe v2) and TTS (Eleven v3). Optional — macOS built-in works without this."
        case .grok:
            return "Enables STT (Grok STT), TTS (Grok TTS), and translation. Optional — macOS built-in works without this."
        }
    }
}

enum STTModel: String, CaseIterable, Identifiable, Codable {
    // OpenAI models
    case gptTranscribe = "gpt-transcribe"

    // Gemini models
    case gemini38Flash = "gemini-3.8-flash"

    // ElevenLabs models
    case scribeV2 = "scribe_v2"

    // Grok models
    case grokSTT = "grok-stt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gptTranscribe: return "GPT Transcribe"
        case .gemini38Flash: return "Gemini 3.8 Flash"
        case .scribeV2: return "Scribe v2"
        case .grokSTT: return "Grok STT"
        }
    }

    var provider: STTProvider {
        switch self {
        case .gptTranscribe:
            return .openAI
        case .gemini38Flash:
            return .gemini
        case .scribeV2:
            return .elevenLabs
        case .grokSTT:
            return .grok
        }
    }
}
