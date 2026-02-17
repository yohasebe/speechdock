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

// MARK: - Default Model ID

extension RealtimeSTTService {
    /// Returns the default model ID from availableModels() (single source of truth)
    var defaultModelId: String {
        availableModels().first(where: { $0.isDefault })?.id
            ?? availableModels().first?.id
            ?? ""
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
    case openAI = "OpenAI"
    case gemini = "Gemini"
    case elevenLabs = "ElevenLabs"
    case grok = "Grok"

    var id: String { rawValue }

    var envKeyName: String? {
        switch self {
        case .macOS: return nil
        case .openAI: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .elevenLabs: return "ELEVENLABS_API_KEY"
        case .grok: return "GROK_API_KEY"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .macOS:
            return false
        default:
            return true
        }
    }

    var description: String {
        switch self {
        case .macOS:
            if #available(macOS 26, *) {
                return NSLocalizedString("Apple Speech (offline, realtime, no time limit)", comment: "STT provider description")
            } else {
                return NSLocalizedString("Apple Speech (offline, fast)", comment: "STT provider description")
            }
        case .openAI: return NSLocalizedString("OpenAI Realtime API (high quality)", comment: "STT provider description")
        case .gemini: return NSLocalizedString("Gemini Live API (multimodal)", comment: "STT provider description")
        case .elevenLabs: return NSLocalizedString("ElevenLabs Scribe v2 (150ms latency)", comment: "STT provider description")
        case .grok: return NSLocalizedString("Grok Voice Agent (low latency)", comment: "STT provider description")
        }
    }

    /// Whether this provider supports file transcription (batch mode)
    var supportsFileTranscription: Bool {
        switch self {
        case .openAI, .gemini, .elevenLabs:
            return true
        case .macOS:
            #if compiler(>=6.1)
            if #available(macOS 26, *) {
                return true
            }
            #endif
            return false
        case .grok:
            return false
        }
    }

    /// Supported audio formats for file transcription
    var supportedAudioFormats: String {
        switch self {
        case .openAI:
            return "MP3, WAV, M4A, FLAC, WebM, MP4"
        case .gemini:
            return "MP3, WAV, AAC, OGG, FLAC"
        case .elevenLabs:
            return "MP3, WAV, M4A, OGG, FLAC"
        case .macOS:
            #if compiler(>=6.1)
            if #available(macOS 26, *) {
                return "MP3, WAV, M4A, AAC, AIFF, FLAC, MP4"
            }
            #endif
            return ""
        case .grok:
            return ""
        }
    }

    /// Maximum file size for file transcription (in MB)
    var maxFileSizeMB: Int {
        switch self {
        case .openAI:
            return 25  // Whisper API limit
        case .gemini:
            return 20  // Gemini inline data limit
        case .elevenLabs:
            return 25  // Scribe v2 limit
        case .macOS:
            #if compiler(>=6.1)
            if #available(macOS 26, *) {
                return 100  // Local processing, conservative limit for M1 stability
            }
            #endif
            return 0
        case .grok:
            return 0
        }
    }

    /// Maximum audio duration for file transcription
    var maxAudioDuration: String {
        switch self {
        case .openAI:
            return "No limit"  // Limited by file size
        case .gemini:
            return "~10 min"  // Approximate based on file size
        case .elevenLabs:
            return "~2 hours"  // ElevenLabs supports long audio
        case .macOS:
            #if compiler(>=6.1)
            if #available(macOS 26, *) {
                return "No limit"
            }
            #endif
            return ""
        case .grok:
            return ""
        }
    }

    /// Short description for file transcription capability
    var fileTranscriptionDescription: String {
        switch self {
        case .openAI:
            return NSLocalizedString("Whisper API (max 25MB)", comment: "File transcription description")
        case .gemini:
            return NSLocalizedString("Gemini API (max 20MB)", comment: "File transcription description")
        case .elevenLabs:
            return NSLocalizedString("Scribe v2 (max 25MB, ~2h audio)", comment: "File transcription description")
        case .grok:
            return NSLocalizedString("Realtime only", comment: "File transcription description")
        case .macOS:
            #if compiler(>=6.1)
            if #available(macOS 26, *) {
                return NSLocalizedString("Apple Speech (offline, max 100MB)", comment: "File transcription description")
            }
            #endif
            return NSLocalizedString("Realtime only", comment: "File transcription description")
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
        case .openAI:
            return OpenAIRealtimeSTT()
        case .gemini:
            return GeminiRealtimeSTT()
        case .elevenLabs:
            return ElevenLabsRealtimeSTT()
        case .grok:
            return GrokRealtimeSTT()
        }
    }
}
