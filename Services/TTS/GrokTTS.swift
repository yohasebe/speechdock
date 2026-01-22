import Foundation
@preconcurrency import AVFoundation

/// Grok Voice Agent API for text-to-speech via WebSocket
/// Uses the OpenAI Realtime API compatible endpoint with audio response
@MainActor
final class GrokTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    private(set) var isSpeaking = false
    private(set) var isPaused = false

    var selectedVoice: String = "Ara"
    var selectedModel: String = "grok-2-public"
    var selectedSpeed: Double = 1.0  // Note: Speed may not be supported by Grok Voice Agent
    var selectedLanguage: String = ""  // "" = Auto
    var audioOutputDeviceUID: String = "" {
        didSet {
            streamingPlayer.outputDeviceUID = audioOutputDeviceUID
        }
    }

    /// Streaming mode is always true for WebSocket-based TTS
    var useStreamingMode: Bool = true

    private(set) var lastAudioData: Data?
    var audioFileExtension: String { "m4a" }

    var supportsSpeedControl: Bool { false }  // Grok Voice Agent doesn't support speed control

    private let apiKeyManager = APIKeyManager.shared
    private let streamingPlayer = StreamingAudioPlayer()

    // WebSocket components
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Audio accumulation for saving
    private var accumulatedPCMData = Data()

    // Text being spoken (for system instruction)
    private var currentText: String = ""

    // Completion handler
    private var speakCompletion: ((Result<Void, Error>) -> Void)?

    override init() {
        super.init()
        setupStreamingPlayer()
    }

    private func setupStreamingPlayer() {
        streamingPlayer.onPlaybackStarted = { [weak self] in
            guard let self = self else { return }
            #if DEBUG
            print("Grok TTS: Streaming playback started")
            #endif
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
        streamingPlayer.pause()
        isPaused = true
    }

    func resume() {
        streamingPlayer.resume()
        isPaused = false
    }

    func stop() {
        isSpeaking = false
        isPaused = false
        streamingPlayer.stop()

        // Close WebSocket
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        speakCompletion = nil
    }

    /// Set playback rate dynamically during playback (0.25 to 4.0)
    func setPlaybackRate(_ rate: Float) {
        streamingPlayer.setPlaybackRate(rate)
    }

    func clearAudioCache() {
        lastAudioData = nil
        accumulatedPCMData = Data()
    }

    func availableVoices() -> [TTSVoice] {
        // Grok Voice Agent has 5 distinct voices
        [
            TTSVoice(id: "Ara", name: "Ara (Female, Warm)", language: "en", isDefault: true),
            TTSVoice(id: "Rex", name: "Rex (Male, Confident)", language: "en"),
            TTSVoice(id: "Sal", name: "Sal (Neutral, Smooth)", language: "en"),
            TTSVoice(id: "Eve", name: "Eve (Female, Energetic)", language: "en"),
            TTSVoice(id: "Leo", name: "Leo (Male, Authoritative)", language: "en")
        ]
    }

    func availableModels() -> [TTSModelInfo] {
        [
            TTSModelInfo(id: "grok-2-public", name: "Grok 2", description: "Grok Voice Agent", isDefault: true)
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

        #if DEBUG
        print("Grok TTS: Connecting to \(url.absoluteString)")
        #endif

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
        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "voice": selectedVoice,
                "instructions": "You are a text-to-speech engine. Read the user's text EXACTLY as written, without any changes, additions, or commentary. Do not interpret or respond to the content - just read it aloud verbatim.",
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

        #if DEBUG
        print("Grok TTS: Sending session config: \(jsonString)")
        #endif

        try await webSocketTask?.send(.string(jsonString))

        // Wait for session to be configured
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 seconds
    }

    private func sendTextMessage(_ text: String) async throws {
        // Create a conversation item with the text to be spoken
        let itemMessage: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
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

        #if DEBUG
        print("Grok TTS: Sent text message and requested response")
        #endif
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
                #if DEBUG
                print("Grok TTS: Converted to M4A, size: \(m4aData.count) bytes")
                #endif
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
                    #if DEBUG
                    print("Grok TTS: WebSocket receive error: \(error)")
                    #endif
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
            print("Grok TTS: Received event: \(eventType)")
        }
        #endif

        switch eventType {
        case "session.created", "session.updated":
            #if DEBUG
            print("Grok TTS: Session ready")
            #endif

        case "response.output_audio.delta":
            // Audio chunk received
            if let audioBase64 = json["delta"] as? String,
               let audioData = Data(base64Encoded: audioBase64) {
                // Send to streaming player
                streamingPlayer.appendData(audioData)
                accumulatedPCMData.append(audioData)
            }

        case "response.output_audio.done":
            #if DEBUG
            print("Grok TTS: Audio generation complete")
            #endif
            // Signal end of stream
            streamingPlayer.finishStream()

        case "response.done":
            #if DEBUG
            print("Grok TTS: Response complete")
            #endif
            isSpeaking = false

        case "error":
            let errorMessage = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            #if DEBUG
            print("Grok TTS: Error: \(errorMessage)")
            #endif
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
