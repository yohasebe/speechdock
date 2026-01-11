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
        }
    }
}
