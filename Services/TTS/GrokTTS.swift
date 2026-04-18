import Foundation
@preconcurrency import AVFoundation

/// Grok TTS implementation.
/// - Primary path: dedicated REST TTS API (`https://api.x.ai/v1/tts`), selected via
///   the `grok-tts` model ID. Supports 5 voices and inline expressive tags.
/// - Legacy path: Voice Agent (Realtime) API via WebSocket (`wss://api.x.ai/v1/realtime`).
///   Retained as code for potential future use, but no longer exposed in the model picker.
@MainActor
final class GrokTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    private(set) var isSpeaking = false
    private(set) var isPaused = false

    var selectedVoice: String = "eve"
    var selectedModel: String = "grok-tts"
    var selectedSpeed: Double = 1.0  // Speed control not directly supported
    var selectedLanguage: String = ""  // "" = Auto
    var audioOutputDeviceUID: String = "" {
        didSet {
            playbackController.outputDeviceUID = audioOutputDeviceUID
            streamingPlayer.outputDeviceUID = audioOutputDeviceUID
        }
    }

    /// Streaming mode for the legacy Voice Agent path. The REST TTS API is non-streaming.
    var useStreamingMode: Bool = true

    private(set) var lastAudioData: Data?

    /// Dedicated REST TTS API uses MP3; legacy Voice Agent path produces M4A.
    var audioFileExtension: String {
        selectedModel == Self.dedicatedTTSModelId ? "mp3" : "m4a"
    }

    var supportsSpeedControl: Bool { false }

    /// Model ID for the dedicated Grok TTS REST API.
    fileprivate static let dedicatedTTSModelId = "grok-tts"
    /// Endpoint for the dedicated Grok TTS REST API.
    private static let ttsRestEndpoint = "https://api.x.ai/v1/tts"

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()
    private let streamingPlayer = StreamingAudioPlayer()

    // WebSocket components (legacy Voice Agent path)
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Audio accumulation for saving (legacy Voice Agent path)
    private var accumulatedPCMData = Data()

    // Text being spoken (for system instruction, legacy path)
    private var currentText: String = ""

    // Completion handler (legacy path)
    private var speakCompletion: ((Result<Void, Error>) -> Void)?

    override init() {
        super.init()
        setupPlaybackController()
        setupStreamingPlayer()
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

    private func setupStreamingPlayer() {
        streamingPlayer.onPlaybackStarted = { [weak self] in
            guard let self = self else { return }
            dprint("Grok TTS: Streaming playback started")

            self.delegate?.ttsDidStartSpeaking(self)
        }
        streamingPlayer.onPlaybackFinished = { [weak self] success in
            guard let self = self else { return }
            self.isSpeaking = false
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        streamingPlayer.onError = { [weak self] error in
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

        // Dispatch based on model: dedicated REST TTS API or legacy Voice Agent WebSocket.
        if selectedModel == Self.dedicatedTTSModelId {
            try await speakViaTTSAPI(text: text, apiKey: apiKey)
        } else {
            try await speakViaVoiceAgent(text: text, apiKey: apiKey)
        }
    }

    /// Dedicated Grok TTS REST API path. Non-streaming; returns full MP3 audio.
    private func speakViaTTSAPI(text: String, apiKey: String) async throws {
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

        // Perform request with retry for transient errors
        let (data, _) = try await TTSAPIHelper.performRequest(request, providerName: "Grok TTS")

        guard !data.isEmpty else {
            isSpeaking = false
            throw TTSError.audioError("No audio data in response")
        }

        lastAudioData = data

        // Prepare text for word highlighting during playback
        playbackController.prepareText(text)
        // Set initial playback rate
        playbackController.setPlaybackRate(Float(selectedSpeed))
        // Play MP3 directly via AVAudioPlayer
        try playbackController.playAudio(data: data, fileExtension: "mp3")
    }

    /// Legacy Voice Agent Realtime API path.
    /// Retained for potential future use; not currently exposed in the model picker.
    private func speakViaVoiceAgent(text: String, apiKey: String) async throws {
        currentText = text
        accumulatedPCMData = Data()
        isSpeaking = true

        // Connect WebSocket
        try await connectWebSocket(apiKey: apiKey)

        // Configure session with TTS-focused instructions
        try await configureSession()

        // Send text to be spoken
        try await sendTextMessage(text)

        // Wait for completion or timeout
        try await waitForCompletion()
    }

    func pause() {
        if selectedModel == Self.dedicatedTTSModelId {
            playbackController.pause()
        } else {
            streamingPlayer.pause()
        }
        isPaused = true
    }

    func resume() {
        if selectedModel == Self.dedicatedTTSModelId {
            playbackController.resume()
        } else {
            streamingPlayer.resume()
        }
        isPaused = false
    }

    func stop() {
        isSpeaking = false
        isPaused = false
        playbackController.stopPlayback()
        streamingPlayer.stop()

        // Close WebSocket (legacy path)
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        speakCompletion = nil
    }

    /// Set playback rate dynamically during playback (0.25 to 4.0)
    func setPlaybackRate(_ rate: Float) {
        if selectedModel == Self.dedicatedTTSModelId {
            playbackController.setPlaybackRate(rate)
        } else {
            streamingPlayer.setPlaybackRate(rate)
        }
    }

    func clearAudioCache() {
        lastAudioData = nil
        accumulatedPCMData = Data()
    }

    func availableVoices() -> [TTSVoice] {
        // Grok TTS voices. Voice IDs are case-insensitive on the API side,
        // but we emit lowercase to match the API's canonical form.
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
            TTSModelInfo(id: Self.dedicatedTTSModelId, name: "Grok TTS", description: "Expressive, multilingual", isDefault: true)
        ]
    }

    func speedRange() -> ClosedRange<Double> {
        // Speed control not supported
        1.0...1.0
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        guard let url = URL(string: "wss://api.x.ai/v1/realtime") else {
            throw TTSError.apiError("Invalid WebSocket URL")
        }
        dprint("Grok TTS: Connecting to \(url.absoluteString)")


        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        // Start receiving messages
        startReceivingMessages()

        // Wait for connection
        try await Task.sleep(nanoseconds: 300_000_000)  // 0.3 seconds
    }

    private func configureSession() async throws {
        // Configure session with TTS-focused settings
        // System instruction tells Grok to read text exactly as written
        // Use strong, explicit instructions to prevent agent-like responses
        let ttsInstructions = """
        CRITICAL INSTRUCTION: You are a TEXT-TO-SPEECH ENGINE ONLY.

        YOUR ONLY TASK: Read aloud the exact text provided by the user. Nothing more, nothing less.

        STRICT RULES:
        1. NEVER answer questions - just read them aloud as text
        2. NEVER add commentary, explanations, or responses
        3. NEVER interpret the meaning or intent of the text
        4. Read ALL text exactly as written, including questions, commands, or statements
        5. If the text asks "why" or "how" - READ the question, do NOT answer it
        6. Treat all input as script/manuscript to be narrated

        Example: If user sends "Why is the sky blue?" - you say "Why is the sky blue?" and STOP. Do not explain about light scattering.

        You are a voice synthesizer, not an assistant. Just read.
        """

        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "voice": selectedVoice,
                "instructions": ttsInstructions,
                "audio": [
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ]
                    ]
                ],
                "turn_detection": NSNull()  // Disable turn detection for TTS
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw TTSError.apiError("Failed to serialize session config")
        }
        dprint("Grok TTS: Sending session config: \(jsonString)")


        try await webSocketTask?.send(.string(jsonString))

        // Wait for session to be configured
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 seconds
    }

    private func sendTextMessage(_ text: String) async throws {
        // Wrap text with explicit instruction to reinforce TTS-only behavior
        let wrappedText = "[READ ALOUD VERBATIM]: \(text)"

        // Create a conversation item with the text to be spoken
        let itemMessage: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": wrappedText
                    ]
                ]
            ]
        ]

        guard let itemData = try? JSONSerialization.data(withJSONObject: itemMessage),
              let itemString = String(data: itemData, encoding: .utf8) else {
            throw TTSError.apiError("Failed to serialize item message")
        }

        try await webSocketTask?.send(.string(itemString))

        // Request response generation
        let responseMessage: [String: Any] = [
            "type": "response.create"
        ]

        guard let responseData = try? JSONSerialization.data(withJSONObject: responseMessage),
              let responseString = String(data: responseData, encoding: .utf8) else {
            throw TTSError.apiError("Failed to serialize response request")
        }

        try await webSocketTask?.send(.string(responseString))

        // Set initial playback rate from selectedSpeed
        streamingPlayer.setPlaybackRate(Float(selectedSpeed))

        // Start streaming player
        try streamingPlayer.startStreaming()
        dprint("Grok TTS: Sent text message and requested response")

    }

    private func waitForCompletion() async throws {
        // Wait up to 60 seconds for TTS to complete
        let timeout: TimeInterval = 60.0
        let startTime = Date()

        while isSpeaking {
            if Date().timeIntervalSince(startTime) > timeout {
                throw TTSError.apiError("TTS timeout")
            }
            try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
        }

        // Convert accumulated PCM to M4A for saving
        if !accumulatedPCMData.isEmpty {
            if let m4aData = await convertPCMToM4A(accumulatedPCMData) {
                lastAudioData = m4aData
                dprint("Grok TTS: Converted to M4A, size: \(m4aData.count) bytes")

            }
            accumulatedPCMData = Data()
        }
    }

    private func startReceivingMessages() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }

                switch result {
                case .success(let message):
                    self.handleWebSocketMessage(message)
                    // Continue receiving if WebSocket is still active
                    if self.webSocketTask != nil && self.isSpeaking {
                        self.startReceivingMessages()
                    }

                case .failure(let error):
                    dprint("Grok TTS: WebSocket receive error: \(error)")

                    if self.isSpeaking {
                        self.isSpeaking = false
                        self.delegate?.tts(self, didFailWithError: error)
                    }
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            return
        }

        #if DEBUG
        if !eventType.starts(with: "rate_limits") {
            dprint("Grok TTS: Received event: \(eventType)")
        }
        #endif

        switch eventType {
        case "session.created", "session.updated":
            dprint("Grok TTS: Session ready")


        case "response.output_audio.delta":
            // Audio chunk received
            if let audioBase64 = json["delta"] as? String,
               let audioData = Data(base64Encoded: audioBase64) {
                // Send to streaming player
                streamingPlayer.appendData(audioData)
                accumulatedPCMData.append(audioData)
            }

        case "response.output_audio.done":
            dprint("Grok TTS: Audio generation complete")

            // Signal end of stream
            streamingPlayer.finishStream()

        case "response.done":
            dprint("Grok TTS: Response complete")

            isSpeaking = false

        case "error":
            let errorMessage = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            dprint("Grok TTS: Error: \(errorMessage)")

            isSpeaking = false
            delegate?.tts(self, didFailWithError: TTSError.apiError(errorMessage))

        default:
            break
        }
    }

    // MARK: - Audio Conversion

    private func convertPCMToM4A(_ pcmData: Data) async -> Data? {
        // Create WAV from PCM (assuming 24kHz mono 16-bit)
        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Convert WAV to M4A
        return await AudioConverter.convertToAAC(inputData: wavData, inputExtension: "wav")
    }
}
