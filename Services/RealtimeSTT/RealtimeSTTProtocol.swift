import Foundation
import AVFoundation

/// Protocol for realtime speech-to-text services
@MainActor
protocol RealtimeSTTService: AnyObject {
    var delegate: RealtimeSTTDelegate? { get set }
    var isListening: Bool { get }
    var selectedModel: String { get set }

    func startListening() async throws
    func stopListening()
    func availableModels() -> [RealtimeSTTModelInfo]
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
    case openAI = "OpenAI Realtime"
    case gemini = "Gemini Live"
    case elevenLabs = "ElevenLabs Scribe"

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
            return MacOSRealtimeSTT()
        case .openAI:
            return OpenAIRealtimeSTT()
        case .gemini:
            return GeminiRealtimeSTT()
        case .elevenLabs:
            return ElevenLabsRealtimeSTT()
        }
    }
}
