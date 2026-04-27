import Foundation
@preconcurrency import AVFoundation

/// Grok TTS via the dedicated REST API (`https://api.x.ai/v1/tts`).
///
/// Uses the `grok-tts` model with 5 voices (eve, ara, rex, sal, leo) and supports
/// inline expressive tags like `[pause]`, `[laugh]`, `<whisper>...</whisper>`, etc.
/// Returns full MP3 audio (non-streaming).
@MainActor
final class GrokTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    private(set) var isSpeaking = false
    private(set) var isPaused = false

    var selectedVoice: String = "eve"
    var selectedModel: String = "grok-tts"
    var selectedSpeed: Double = 1.0  // Speed control not supported by the API
    var selectedLanguage: String = ""  // "" = Auto
    var audioOutputDeviceUID: String = "" {
        didSet {
            playbackController.outputDeviceUID = audioOutputDeviceUID
        }
    }

    /// REST TTS API is always non-streaming, so this property is intentionally inert.
    /// It exists only for `TTSService` protocol conformance; setting it from generic
    /// TTS code (e.g. AppState's save flow) has no effect on Grok and that's expected.
    var useStreamingMode: Bool = false

    private(set) var lastAudioData: Data?

    var audioFileExtension: String { "mp3" }

    var supportsSpeedControl: Bool { false }

    private static let ttsRestEndpoint = "https://api.x.ai/v1/tts"

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()

    override init() {
        super.init()
        setupPlaybackController()
    }

    private func setupPlaybackController() {
        playbackController.onPlaybackStarted = { [weak self] in
            guard let self = self else { return }
            self.delegate?.ttsDidStartSpeaking(self)
        }
        playbackController.onWordHighlight = { [weak self] range, text in
            guard let self = self else { return }
            self.delegate?.tts(self, willSpeakRange: range, of: text)
        }
        playbackController.onFinishSpeaking = { [weak self] success in
            guard let self = self else { return }
            self.isSpeaking = false
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        playbackController.onError = { [weak self] error in
            guard let self = self else { return }
            self.isSpeaking = false
            self.delegate?.tts(self, didFailWithError: error)
        }
    }

    func speak(text: String) async throws {
        guard !text.isEmpty else {
            throw TTSError.noTextProvided
        }

        guard let apiKey = apiKeyManager.getAPIKey(for: .grok) else {
            throw TTSError.apiError("Grok API key not found")
        }

        stop()

        guard let url = URL(string: Self.ttsRestEndpoint) else {
            throw TTSError.apiError("Invalid Grok TTS endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let language = selectedLanguage.isEmpty ? "auto" : selectedLanguage
        let voiceId = selectedVoice.lowercased()

        let body: [String: Any] = [
            "text": text,
            "voice_id": voiceId,
            "language": language,
            "output_format": [
                "codec": "mp3",
                "sample_rate": 24000,
                "bit_rate": 128000
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        isSpeaking = true

        let (data, _) = try await TTSAPIHelper.performRequest(request, providerName: "Grok TTS")

        guard !data.isEmpty else {
            isSpeaking = false
            throw TTSError.audioError("No audio data in response")
        }

        lastAudioData = data

        playbackController.prepareText(text)
        playbackController.setPlaybackRate(Float(selectedSpeed))
        try playbackController.playAudio(data: data, fileExtension: "mp3")
    }

    func pause() {
        playbackController.pause()
        isPaused = true
    }

    func resume() {
        playbackController.resume()
        isPaused = false
    }

    func stop() {
        isSpeaking = false
        isPaused = false
        playbackController.stopPlayback()
    }

    /// Set playback rate dynamically during playback (0.25 to 4.0)
    func setPlaybackRate(_ rate: Float) {
        playbackController.setPlaybackRate(rate)
    }

    func clearAudioCache() {
        lastAudioData = nil
    }

    func availableVoices() -> [TTSVoice] {
        // Voice IDs are case-insensitive on the API side; we emit lowercase canonical form.
        [
            TTSVoice(id: "eve", name: "Eve (Energetic)", language: "multi", isDefault: true),
            TTSVoice(id: "ara", name: "Ara (Warm)", language: "multi"),
            TTSVoice(id: "rex", name: "Rex (Confident)", language: "multi"),
            TTSVoice(id: "sal", name: "Sal (Smooth)", language: "multi"),
            TTSVoice(id: "leo", name: "Leo (Authoritative)", language: "multi")
        ]
    }

    func availableModels() -> [TTSModelInfo] {
        [
            TTSModelInfo(id: "grok-tts", name: "Grok TTS", description: "Expressive, multilingual", isDefault: true)
        ]
    }

    func speedRange() -> ClosedRange<Double> {
        // Speed control not supported by the API
        1.0...1.0
    }
}
