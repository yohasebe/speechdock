import Foundation

/// Gemini speech generation with local playback and audio export.
@MainActor
final class GeminiTTS: NSObject, TTSService {
    private let synthesis = SynthesisLifecycle()
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool {
        playbackController.isSpeaking
    }
    var isPaused: Bool {
        playbackController.isPaused
    }

    var selectedVoice: String = "Zephyr"  // Default voice
    var selectedModel: String = GeminiTTSModels.defaultID
    var selectedSpeed: Double = 1.0  // Local playback speed; saved audio stays at 1.0x
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects from text)
    var audioOutputDeviceUID: String = "" {
        didSet {
            playbackController.outputDeviceUID = audioOutputDeviceUID
        }
    }

    var useStreamingMode: Bool { get { false } set {} }

    private(set) var lastAudioData: Data?

    /// Track the actual file extension of lastAudioData (m4a or wav fallback)
    private var _audioFileExtension: String = "m4a"
    var audioFileExtension: String { _audioFileExtension }

    var supportsSpeedControl: Bool { true }

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

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
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        playbackController.onError = { [weak self] error in
            guard let self = self else { return }
            self.delegate?.tts(self, didFailWithError: error)
        }
    }

    func speak(text: String) async throws {
        guard !text.isEmpty else { throw TTSError.noTextProvided }
        guard let apiKey = await apiKeyManager.apiKey(for: .gemini) else {
            throw TTSError.apiError(apiKeyManager.unavailableReason(for: .gemini))
        }
        stop()
        selectedModel = GeminiTTSModels.resolvedID(selectedModel)
        try await speakNonStreaming(text: text, apiKey: apiKey)
    }

    /// Non-streaming playback - waits for full audio before playing
    private func speakNonStreaming(text: String, apiKey: String) async throws {
        let generation = synthesis.generation
        try synthesis.check(generation)
        // Prepare text for highlighting
        playbackController.prepareText(text)

        let finalAudioData = try await fetchWAV(text: text, apiKey: apiKey)
        try synthesis.check(generation)
        let sourceExt = "wav"

        // Convert to M4A (AAC) for smaller file size - await completion for Save Audio support
        if let m4aData = await AudioConverter.convertToAAC(inputData: finalAudioData, inputExtension: sourceExt) {
            try synthesis.check(generation)
            lastAudioData = m4aData
            _audioFileExtension = "m4a"
        } else {
            try synthesis.check(generation)
            // Fallback to original format if conversion fails
            lastAudioData = finalAudioData
            _audioFileExtension = sourceExt
        }

        // Set initial playback rate from selectedSpeed
        playbackController.setPlaybackRate(Float(selectedSpeed))

        // Play the audio
        try playbackController.playAudio(data: finalAudioData, fileExtension: sourceExt)
    }

    /// Requests speech for `text` and returns it as WAV data.
    private func fetchWAV(text: String, apiKey: String) async throws -> Data {
        // Build API request
        // Pass the API key via the x-goog-api-key header instead of a URL query
        // parameter, so the key can't leak into error logs through the request URL
        let modelId = selectedModel.isEmpty ? defaultModelId : selectedModel
        let urlString = "\(baseURL)/\(modelId):generateContent"
        guard let url = URL(string: urlString) else {
            throw TTSError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // Validate voice - use default if invalid, and convert to lowercase
        let validVoice = Self.validVoiceIds.contains(selectedVoice.lowercased()) ? selectedVoice.lowercased() : "zephyr"

        // Send only the original text; speed is controlled during local playback.
        let textToSpeak = text

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": textToSpeak]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": validVoice
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Perform request with retry logic for transient errors
        let (data, _) = try await TTSAPIHelper.performRequest(request, providerName: "Gemini")

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            // Log raw response body to help diagnose issues like text-token responses
            // or content rejections.
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            dprint("Gemini TTS: Invalid response format. Raw body (first 500 bytes): \(snippet)")
            throw TTSError.apiError("Invalid response format")
        }

        // Normalize each container separately before joining; embedded RIFF headers
        // would otherwise become audible samples in multi-part responses.
        return try GeminiTTSAudio.makeWAV(from: parts)
    }

    func pause() { playbackController.pause() }
    func resume() { playbackController.resume() }
    func stop() {
        synthesis.invalidate()
        playbackController.stopPlayback()
    }
    func setPlaybackRate(_ rate: Float) { playbackController.setPlaybackRate(rate) }
    func clearAudioCache() {
        lastAudioData = nil
        _audioFileExtension = "m4a"
    }

    // MARK: - Gemini-specific Helpers

    /// Valid Gemini voice IDs (lowercase)
    private static let validVoiceIds: Set<String> = [
        "zephyr", "puck", "charon", "kore", "fenrir", "aoede", "orus",
        "leda", "callirrhoe", "autonoe", "enceladus", "iapetus", "umbriel",
        "algieba", "despina", "erinome", "algenib", "rasalgethi", "laomedeia",
        "achernar", "alnilam", "schedar", "gacrux", "pulcherrima", "achird",
        "zubenelgenubi", "vindemiatrix", "sadachbia", "sadaltager", "sulafat"
    ]

    func availableVoices() -> [TTSVoice] {
        // Gemini TTS available voices (30 prebuilt voices)
        [
            TTSVoice(id: "zephyr", name: "Zephyr", language: "multi", isDefault: true),
            TTSVoice(id: "puck", name: "Puck", language: "multi"),
            TTSVoice(id: "charon", name: "Charon", language: "multi"),
            TTSVoice(id: "kore", name: "Kore", language: "multi"),
            TTSVoice(id: "fenrir", name: "Fenrir", language: "multi"),
            TTSVoice(id: "aoede", name: "Aoede", language: "multi"),
            TTSVoice(id: "orus", name: "Orus", language: "multi"),
            TTSVoice(id: "leda", name: "Leda", language: "multi"),
            TTSVoice(id: "callirrhoe", name: "Callirrhoe", language: "multi"),
            TTSVoice(id: "autonoe", name: "Autonoe", language: "multi"),
            TTSVoice(id: "enceladus", name: "Enceladus", language: "multi"),
            TTSVoice(id: "iapetus", name: "Iapetus", language: "multi"),
            TTSVoice(id: "umbriel", name: "Umbriel", language: "multi"),
            TTSVoice(id: "algieba", name: "Algieba", language: "multi"),
            TTSVoice(id: "despina", name: "Despina", language: "multi"),
            TTSVoice(id: "erinome", name: "Erinome", language: "multi"),
            TTSVoice(id: "algenib", name: "Algenib", language: "multi"),
            TTSVoice(id: "rasalgethi", name: "Rasalgethi", language: "multi"),
            TTSVoice(id: "laomedeia", name: "Laomedeia", language: "multi"),
            TTSVoice(id: "achernar", name: "Achernar", language: "multi"),
            TTSVoice(id: "alnilam", name: "Alnilam", language: "multi"),
            TTSVoice(id: "schedar", name: "Schedar", language: "multi"),
            TTSVoice(id: "gacrux", name: "Gacrux", language: "multi"),
            TTSVoice(id: "pulcherrima", name: "Pulcherrima", language: "multi"),
            TTSVoice(id: "achird", name: "Achird", language: "multi"),
            TTSVoice(id: "zubenelgenubi", name: "Zubenelgenubi", language: "multi"),
            TTSVoice(id: "vindemiatrix", name: "Vindemiatrix", language: "multi"),
            TTSVoice(id: "sadachbia", name: "Sadachbia", language: "multi"),
            TTSVoice(id: "sadaltager", name: "Sadaltager", language: "multi"),
            TTSVoice(id: "sulafat", name: "Sulafat", language: "multi")
        ]
    }

    func availableModels() -> [TTSModelInfo] {
        GeminiTTSModels.available
    }

    func speedRange() -> ClosedRange<Double> {
        0.5...2.0  // Local playback rate; exports retain their generated pace.
    }

}

// MARK: - Fetch ahead (live subtitles)

extension GeminiTTS: PresynthesizingTTSService {
    /// Fetches audio without touching playback, so it can overlap the current line.
    func synthesize(text: String) async throws -> PreparedSpeech {
        guard !text.isEmpty else { throw TTSError.noTextProvided }
        guard let apiKey = await apiKeyManager.apiKey(for: .gemini) else {
            throw TTSError.apiError(apiKeyManager.unavailableReason(for: .gemini))
        }
        selectedModel = GeminiTTSModels.resolvedID(selectedModel)
        return PreparedSpeech(text: text, data: try await fetchWAV(text: text, apiKey: apiKey), fileExtension: "wav")
    }

    /// Plays straight away; skips the AAC conversion that only Save Audio needs.
    func play(_ speech: PreparedSpeech) throws {
        playbackController.prepareText(speech.text)
        playbackController.setPlaybackRate(Float(selectedSpeed))
        try playbackController.playAudio(data: speech.data, fileExtension: speech.fileExtension)
    }
}
