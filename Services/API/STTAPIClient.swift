import Foundation

protocol STTAPIClient {
    func transcribe(
        audioData: Data,
        model: STTModel,
        language: String?
    ) async throws -> TranscriptionResult
}

enum STTAPIClientFactory {
    static func makeClient(for provider: STTProvider) -> STTAPIClient {
        switch provider {
        case .openAI:
            return OpenAISTTClient()
        case .gemini:
            return GeminiSTTClient()
        case .elevenLabs:
            return ElevenLabsSTTClient()
        case .grok:
            // Grok only supports realtime STT via Voice Agent API, not batch transcription
            // Return a placeholder that will throw an error if used
            return GrokSTTClient()
        }
    }
}

/// Placeholder STT client for Grok (batch transcription not supported)
struct GrokSTTClient: STTAPIClient {
    func transcribe(audioData: Data, model: STTModel, language: String?) async throws -> TranscriptionResult {
        throw NSError(domain: "GrokSTT", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Grok only supports realtime speech-to-text via Voice Agent API. Use the realtime STT provider instead."
        ])
    }
}
