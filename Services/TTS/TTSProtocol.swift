import Foundation
import AVFoundation

/// Error types for TTS services
enum TTSError: LocalizedError {
    case apiError(String)
    case audioError(String)
    case networkError(String)
    case noTextProvided

    var errorDescription: String? {
        switch self {
        case .apiError(let message): return "API Error: \(message)"
        case .audioError(let message): return "Audio Error: \(message)"
        case .networkError(let message): return "Network Error: \(message)"
        case .noTextProvided: return "No text provided for speech"
        }
    }
}

/// Protocol for text-to-speech services
@MainActor
protocol TTSService: AnyObject {
    var delegate: TTSDelegate? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    var selectedVoice: String { get set }
    var selectedModel: String { get set }
    var selectedSpeed: Double { get set }  // Speed multiplier (1.0 = normal)
    var selectedLanguage: String { get set }  // "" = Auto (only used by ElevenLabs)
    var audioOutputDeviceUID: String { get set }  // "" = System Default

    /// Last generated audio data (nil for providers that don't support saving, e.g., macOS)
    var lastAudioData: Data? { get }

    /// File extension for the audio format (e.g., "mp3", "wav")
    var audioFileExtension: String { get }

    func speak(text: String) async throws
    func pause()
    func resume()
    func stop()

    /// Clear cached audio data to free memory
    func clearAudioCache()

    func availableVoices() -> [TTSVoice]
    func availableModels() -> [TTSModelInfo]

    /// Returns the valid speed range for this provider
    func speedRange() -> ClosedRange<Double>

    /// Returns whether speed control is supported
    var supportsSpeedControl: Bool { get }
}

/// Represents a TTS model option
struct TTSModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let isDefault: Bool

    init(id: String, name: String, description: String = "", isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.isDefault = isDefault
    }
}

/// Voice quality tier for TTS voices (primarily for macOS system voices)
enum VoiceQuality: Int, Comparable, Hashable {
    case standard = 0
    case enhanced = 1
    case premium = 2

    static func < (lhs: VoiceQuality, rhs: VoiceQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .standard: return ""
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "circle"
        case .enhanced: return "star.leadinghalf.filled"
        case .premium: return "star.fill"
        }
    }
}

/// Represents a TTS voice
struct TTSVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let isDefault: Bool
    let quality: VoiceQuality

    init(id: String, name: String, language: String = "", isDefault: Bool = false, quality: VoiceQuality = .standard) {
        self.id = id
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.quality = quality
    }
}

/// Delegate for receiving TTS events
@MainActor
protocol TTSDelegate: AnyObject {
    /// Called when a word is about to be spoken
    func tts(_ service: TTSService, willSpeakRange range: NSRange, of text: String)

    /// Called when speech finishes
    func tts(_ service: TTSService, didFinishSpeaking successfully: Bool)

    /// Called when an error occurs
    func tts(_ service: TTSService, didFailWithError error: Error)
}

/// TTS provider types
enum TTSProvider: String, CaseIterable, Identifiable, Codable {
    case macOS = "macOS"
    case openAI = "OpenAI"
    case gemini = "Gemini"
    case elevenLabs = "ElevenLabs"

    var id: String { rawValue }

    var envKeyName: String? {
        switch self {
        case .macOS: return nil
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .elevenLabs: return "ELEVENLABS_API_KEY"
        }
    }

    var requiresAPIKey: Bool {
        self != .macOS
    }

    var description: String {
        switch self {
        case .macOS: return "Local (offline, fast)"
        case .openAI: return "OpenAI TTS (high quality)"
        case .gemini: return "Gemini TTS (multilingual)"
        case .elevenLabs: return "ElevenLabs (natural voices)"
        }
    }
}

/// Factory for creating TTS services
enum TTSFactory {
    @MainActor
    static func makeService(for provider: TTSProvider) -> TTSService {
        switch provider {
        case .macOS:
            return MacOSTTS()
        case .openAI:
            return OpenAITTS()
        case .gemini:
            return GeminiTTS()
        case .elevenLabs:
            return ElevenLabsTTS()
        }
    }
}
