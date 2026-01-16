import Foundation
import AVFoundation

/// Audio input source for STT services
enum STTAudioSource {
    case microphone           // Use built-in microphone capture
    case external             // Receive audio from external source via processAudioBuffer
}

/// Protocol for realtime speech-to-text services
@MainActor
protocol RealtimeSTTService: AnyObject {
    var delegate: RealtimeSTTDelegate? { get set }
    var isListening: Bool { get }
    var selectedModel: String { get set }
    var selectedLanguage: String { get set }  // "" = Auto
    var audioInputDeviceUID: String { get set }  // "" = System Default
    var audioSource: STTAudioSource { get set }  // Audio input source

    // VAD auto-stop settings (only used by providers that support it)
    var vadMinimumRecordingTime: TimeInterval { get set }  // Seconds before auto-stop activates
    var vadSilenceDuration: TimeInterval { get set }  // Seconds of silence to trigger auto-stop

    func startListening() async throws
    func stopListening()
    func availableModels() -> [RealtimeSTTModelInfo]

    /// Process audio buffer from external source (system audio, app audio)
    /// Only used when audioSource == .external
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer)
}

/// Represents an STT model option
struct RealtimeSTTModelInfo: Identifiable, Hashable {
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

/// Delegate for receiving realtime transcription updates
@MainActor
protocol RealtimeSTTDelegate: AnyObject {
    /// Called when partial (interim) transcription is available
    func realtimeSTT(_ service: RealtimeSTTService, didReceivePartialResult text: String)

    /// Called when final transcription for a segment is available
    func realtimeSTT(_ service: RealtimeSTTService, didReceiveFinalResult text: String)

    /// Called when an error occurs
    func realtimeSTT(_ service: RealtimeSTTService, didFailWithError error: Error)

    /// Called when listening state changes
    func realtimeSTT(_ service: RealtimeSTTService, didChangeListeningState isListening: Bool)
}

/// Realtime STT provider types
enum RealtimeSTTProvider: String, CaseIterable, Identifiable, Codable {
    case macOS = "macOS"
    case localWhisper = "Local Whisper"
    case openAI = "OpenAI"
    case gemini = "Gemini"
    case elevenLabs = "ElevenLabs"

    var id: String { rawValue }

    var envKeyName: String? {
        switch self {
        case .macOS: return nil
        case .localWhisper: return nil
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .elevenLabs: return "ELEVENLABS_API_KEY"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .macOS, .localWhisper:
            return false
        default:
            return true
        }
    }

    var description: String {
        switch self {
        case .macOS:
            if #available(macOS 26, *) {
                return "Apple Speech (offline, realtime, no time limit)"
            } else {
                return "Apple Speech (offline, fast)"
            }
        case .localWhisper: return "WhisperKit (offline, high quality)"
        case .openAI: return "OpenAI Realtime API (high quality)"
        case .gemini: return "Gemini Live API (multimodal)"
        case .elevenLabs: return "ElevenLabs Scribe v2 (150ms latency)"
        }
    }
}

/// Factory for creating realtime STT services
enum RealtimeSTTFactory {
    @MainActor
    static func makeService(for provider: RealtimeSTTProvider) -> RealtimeSTTService {
        switch provider {
        case .macOS:
            // Use SpeechAnalyzer on macOS 26+ for better performance and no time limit
            // SpeechAnalyzerSTT requires Swift 6.1+ compiler (macOS 26 SDK)
            #if compiler(>=6.1)
            if #available(macOS 26, *) {
                return SpeechAnalyzerSTT()
            } else {
                return MacOSRealtimeSTT()
            }
            #else
            return MacOSRealtimeSTT()
            #endif
        case .localWhisper:
            return LocalWhisperSTT()
        case .openAI:
            return OpenAIRealtimeSTT()
        case .gemini:
            return GeminiRealtimeSTT()
        case .elevenLabs:
            return ElevenLabsRealtimeSTT()
        }
    }
}
