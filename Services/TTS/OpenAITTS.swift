import Foundation
@preconcurrency import AVFoundation

/// OpenAI TTS API implementation
@MainActor
final class OpenAITTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool { playbackController.isSpeaking }
    var isPaused: Bool { playbackController.isPaused }

    var selectedVoice: String = "alloy"
    var selectedModel: String = "gpt-4o-mini-tts-2025-12-15"
    var selectedSpeed: Double = 1.0  // Speed multiplier (0.25-4.0 for tts-1/tts-1-hd)
    var selectedLanguage: String = ""  // "" = Auto (OpenAI auto-detects from text)
    var audioOutputDeviceUID: String = "" {
        didSet { playbackController.outputDeviceUID = audioOutputDeviceUID }
    }

    private(set) var lastAudioData: Data?
    var audioFileExtension: String { "mp3" }

    var supportsSpeedControl: Bool {
        // gpt-4o-mini-tts models don't support speed parameter directly
        !selectedModel.hasPrefix("gpt-4o-mini-tts")
    }

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()
    private let endpoint = "https://api.openai.com/v1/audio/speech"

    override init() {
        super.init()
        setupPlaybackController()
    }

    private func setupPlaybackController() {
        playbackController.onWordHighlight = { [weak self] range, text in
            guard let self = self else { return }
            self.delegate?.tts(self, willSpeakRange: range, of: text)
        }
        playbackController.onFinishSpeaking = { [weak self] success in
            guard let self = self else { return }
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        playbackController.onError = { [weak self] error in
            guard let self = self else { return }
            self.delegate?.tts(self, didFailWithError: error)
        }
    }

    func speak(text: String) async throws {
        guard !text.isEmpty else {
            throw TTSError.noTextProvided
        }

        guard let apiKey = apiKeyManager.getAPIKey(for: .openAI) else {
            throw TTSError.apiError("OpenAI API key not found")
        }

        stop()

        // Prepare text for highlighting
        playbackController.prepareText(text)

        // Build API request
        guard let url = URL(string: endpoint) else {
            throw TTSError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        // Validate voice - use default if invalid
        let validVoice = Self.validVoiceIds.contains(selectedVoice) ? selectedVoice : "alloy"
        let model = selectedModel.isEmpty ? "gpt-4o-mini-tts" : selectedModel

        // Build request body
        var body: [String: Any] = [
            "input": text,
            "model": model,
            "voice": validVoice,
            "response_format": "mp3"
        ]

        // Add speed parameter for models that support it (tts-1, tts-1-hd)
        // Note: gpt-4o-mini-tts models don't support speed parameter
        if !model.hasPrefix("gpt-4o-mini-tts") {
            // Clamp speed to valid range (0.25 to 4.0)
            let clampedSpeed = max(0.25, min(4.0, selectedSpeed))
            body["speed"] = clampedSpeed
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TTSError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Store audio data for saving
        lastAudioData = data

        // Play the audio
        try playbackController.playAudio(data: data, fileExtension: "mp3")
    }

    func pause() {
        playbackController.pause()
    }

    func resume() {
        playbackController.resume()
    }

    func stop() {
        playbackController.stopPlayback()
    }

    func clearAudioCache() {
        lastAudioData = nil
    }

    /// Valid OpenAI voice IDs
    private static let validVoiceIds: Set<String> = [
        "alloy", "ash", "ballad", "coral", "echo", "fable",
        "onyx", "nova", "sage", "shimmer", "verse", "marin", "cedar"
    ]

    func availableVoices() -> [TTSVoice] {
        [
            TTSVoice(id: "alloy", name: "Alloy", language: "en", isDefault: true),
            TTSVoice(id: "ash", name: "Ash", language: "en"),
            TTSVoice(id: "ballad", name: "Ballad", language: "en"),
            TTSVoice(id: "cedar", name: "Cedar", language: "en"),
            TTSVoice(id: "coral", name: "Coral", language: "en"),
            TTSVoice(id: "echo", name: "Echo", language: "en"),
            TTSVoice(id: "fable", name: "Fable", language: "en"),
            TTSVoice(id: "marin", name: "Marin", language: "en"),
            TTSVoice(id: "nova", name: "Nova", language: "en"),
            TTSVoice(id: "onyx", name: "Onyx", language: "en"),
            TTSVoice(id: "sage", name: "Sage", language: "en"),
            TTSVoice(id: "shimmer", name: "Shimmer", language: "en"),
            TTSVoice(id: "verse", name: "Verse", language: "en")
        ]
    }

    func availableModels() -> [TTSModelInfo] {
        [
            TTSModelInfo(id: "gpt-4o-mini-tts-2025-12-15", name: "GPT-4o Mini TTS (Dec 2025)", description: "Latest, fast (no speed control)", isDefault: true),
            TTSModelInfo(id: "gpt-4o-mini-tts", name: "GPT-4o Mini TTS", description: "Fast (no speed control)"),
            TTSModelInfo(id: "tts-1", name: "TTS-1", description: "Standard quality"),
            TTSModelInfo(id: "tts-1-hd", name: "TTS-1 HD", description: "High quality")
        ]
    }

    func speedRange() -> ClosedRange<Double> {
        // OpenAI TTS supports speed from 0.25 to 4.0
        // Note: gpt-4o-mini-tts doesn't support speed parameter
        0.25...4.0
    }
}
