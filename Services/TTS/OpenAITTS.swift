import Foundation
@preconcurrency import AVFoundation

/// OpenAI TTS API implementation with streaming support
@MainActor
final class OpenAITTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool {
        useStreamingMode ? streamingPlayer.isSpeaking : playbackController.isSpeaking
    }
    var isPaused: Bool {
        useStreamingMode ? streamingPlayer.isPaused : playbackController.isPaused
    }

    var selectedVoice: String = "alloy"
    var selectedModel: String = "gpt-4o-mini-tts-2025-12-15"
    var selectedSpeed: Double = 1.0  // Speed multiplier (0.25-4.0 for tts-1/tts-1-hd)
    var selectedLanguage: String = ""  // "" = Auto (OpenAI auto-detects from text)
    var audioOutputDeviceUID: String = "" {
        didSet {
            playbackController.outputDeviceUID = audioOutputDeviceUID
            streamingPlayer.outputDeviceUID = audioOutputDeviceUID
        }
    }

    /// Enable streaming mode for lower latency (default: true)
    var useStreamingMode: Bool = true

    private(set) var lastAudioData: Data?
    var audioFileExtension: String { useStreamingMode ? "pcm" : "mp3" }

    var supportsSpeedControl: Bool {
        // gpt-4o-mini-tts models don't support speed parameter directly
        !selectedModel.hasPrefix("gpt-4o-mini-tts")
    }

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()
    private let streamingPlayer = StreamingAudioPlayer()
    private let endpoint = "https://api.openai.com/v1/audio/speech"

    /// Task for streaming request (to allow cancellation)
    private var streamingTask: Task<Void, Never>?

    /// Accumulated PCM data for saving (streaming mode)
    private var accumulatedPCMData = Data()

    override init() {
        super.init()
        setupPlaybackController()
        setupStreamingPlayer()
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

    private func setupStreamingPlayer() {
        streamingPlayer.onPlaybackStarted = {
            #if DEBUG
            print("OpenAI TTS: Streaming playback started")
            #endif
        }
        streamingPlayer.onPlaybackFinished = { [weak self] success in
            guard let self = self else { return }
            // Store accumulated PCM data for potential saving
            if !self.accumulatedPCMData.isEmpty {
                self.lastAudioData = self.accumulatedPCMData
            }
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        streamingPlayer.onError = { [weak self] error in
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

        if useStreamingMode {
            try await speakStreaming(text: text, apiKey: apiKey)
        } else {
            try await speakNonStreaming(text: text, apiKey: apiKey)
        }
    }

    /// Streaming playback - starts playing as soon as first chunks arrive
    private func speakStreaming(text: String, apiKey: String) async throws {
        accumulatedPCMData = Data()

        // Build API request for PCM streaming
        guard let url = URL(string: endpoint) else {
            throw TTSError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let validVoice = Self.validVoiceIds.contains(selectedVoice) ? selectedVoice : "alloy"
        let model = selectedModel.isEmpty ? "gpt-4o-mini-tts" : selectedModel

        // Use PCM format for lowest latency streaming
        var body: [String: Any] = [
            "input": text,
            "model": model,
            "voice": validVoice,
            "response_format": "pcm"  // 24kHz, 16-bit signed, little-endian, mono
        ]

        // Add speed parameter for models that support it
        if !model.hasPrefix("gpt-4o-mini-tts") {
            let clampedSpeed = max(0.25, min(4.0, selectedSpeed))
            body["speed"] = clampedSpeed
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Start streaming player
        try streamingPlayer.startStreaming()

        #if DEBUG
        print("OpenAI TTS: Starting streaming request")
        #endif

        // Stream response using URLSession.bytes
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        // Check response status
        guard let httpResponse = response as? HTTPURLResponse else {
            streamingPlayer.stop()
            throw TTSError.apiError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            streamingPlayer.stop()
            // Try to read error message
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 1024 { break }  // Limit error reading
            }
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw TTSError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Process streaming bytes
        var chunkBuffer = Data()
        let chunkSize = 4800  // ~100ms of audio at 24kHz mono 16-bit

        for try await byte in bytes {
            chunkBuffer.append(byte)

            // Send chunks to player when buffer is full
            if chunkBuffer.count >= chunkSize {
                streamingPlayer.appendData(chunkBuffer)
                accumulatedPCMData.append(chunkBuffer)
                chunkBuffer = Data()
            }
        }

        // Send any remaining data
        if !chunkBuffer.isEmpty {
            streamingPlayer.appendData(chunkBuffer)
            accumulatedPCMData.append(chunkBuffer)
        }

        // Signal end of stream
        streamingPlayer.finishStream()

        #if DEBUG
        print("OpenAI TTS: Streaming complete, total bytes: \(accumulatedPCMData.count)")
        #endif
    }

    /// Non-streaming playback - waits for full audio before playing
    private func speakNonStreaming(text: String, apiKey: String) async throws {
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

        // Perform request with retry logic for transient errors
        let (data, _) = try await TTSAPIHelper.performRequest(request, providerName: "OpenAI")

        // Store audio data for saving
        lastAudioData = data

        // Play the audio
        try playbackController.playAudio(data: data, fileExtension: "mp3")
    }

    func pause() {
        if useStreamingMode {
            streamingPlayer.pause()
        } else {
            playbackController.pause()
        }
    }

    func resume() {
        if useStreamingMode {
            streamingPlayer.resume()
        } else {
            playbackController.resume()
        }
    }

    func stop() {
        streamingTask?.cancel()
        streamingTask = nil
        streamingPlayer.stop()
        playbackController.stopPlayback()
    }

    func clearAudioCache() {
        lastAudioData = nil
        accumulatedPCMData = Data()
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
