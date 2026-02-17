import Foundation
@preconcurrency import AVFoundation

/// ElevenLabs TTS API implementation with streaming support
@MainActor
final class ElevenLabsTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool {
        useStreamingMode ? streamingPlayer.isSpeaking : playbackController.isSpeaking
    }
    var isPaused: Bool {
        useStreamingMode ? streamingPlayer.isPaused : playbackController.isPaused
    }

    var selectedVoice: String = "21m00Tcm4TlvDq8ikWAM"  // Default: Rachel
    var selectedModel: String = "eleven_v3"
    var selectedSpeed: Double = 1.0  // Speed multiplier (ElevenLabs range: 0.5-2.0)
    var selectedLanguage: String = ""  // "" = Auto (ElevenLabs uses language_code for Turbo/Flash v2.5)
    var audioOutputDeviceUID: String = "" {
        didSet {
            playbackController.outputDeviceUID = audioOutputDeviceUID
            streamingPlayer.outputDeviceUID = audioOutputDeviceUID
        }
    }

    /// Enable streaming mode for lower latency (default: true)
    var useStreamingMode: Bool = true

    private(set) var lastAudioData: Data?
    var audioFileExtension: String { useStreamingMode ? "m4a" : "mp3" }

    var supportsSpeedControl: Bool { true }

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()
    private let streamingPlayer = StreamingAudioPlayer()
    private let endpoint = "https://api.elevenlabs.io/v1/text-to-speech"

    /// Accumulated PCM data for saving (streaming mode)
    private var accumulatedPCMData = Data()

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
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        playbackController.onError = { [weak self] error in
            guard let self = self else { return }
            self.delegate?.tts(self, didFailWithError: error)
        }
    }

    private func setupStreamingPlayer() {
        streamingPlayer.onPlaybackStarted = { [weak self] in
            guard let self = self else { return }
            dprint("ElevenLabs TTS: Streaming playback started")

            self.delegate?.ttsDidStartSpeaking(self)
        }
        streamingPlayer.onPlaybackFinished = { [weak self] success in
            guard let self = self else { return }
            // Note: M4A conversion is handled in speakStreaming() after stream completes
            // Don't convert here - lastAudioData is already set by speakStreaming()
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

        guard let apiKey = apiKeyManager.getAPIKey(for: .elevenLabs) else {
            throw TTSError.apiError("ElevenLabs API key not found")
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
        let voiceId = selectedVoice.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : selectedVoice
        // Use streaming endpoint with PCM format (24kHz, mono, 16-bit)
        let urlString = "\(endpoint)/\(voiceId)/stream?output_format=pcm_24000"
        guard let url = URL(string: urlString) else {
            throw TTSError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let modelId = selectedModel.isEmpty ? defaultModelId : selectedModel

        // Note: Speed is controlled locally via AVAudioUnitTimePitch, not via API
        var body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        // Add language_code only for models that support it (Turbo/Flash v2.5, Multilingual v2)
        // eleven_v3 and eleven_monolingual_v1 do NOT support language_code parameter
        let supportsLanguageCode = modelId.contains("v2") || modelId.contains("multilingual")
        if supportsLanguageCode,
           !selectedLanguage.isEmpty,
           let langCode = LanguageCode(rawValue: selectedLanguage),
           let elevenLabsCode = langCode.toElevenLabsTTSCode() {
            body["language_code"] = elevenLabsCode
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Set initial playback rate from selectedSpeed
        streamingPlayer.setPlaybackRate(Float(selectedSpeed))

        // Start streaming player
        try streamingPlayer.startStreaming()
        dprint("ElevenLabs TTS: Starting streaming request")


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
                if errorData.count > 1024 { break }
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
        dprint("ElevenLabs TTS: Streaming complete, total bytes: \(accumulatedPCMData.count)")


        // Convert accumulated PCM to M4A for saving (await to ensure lastAudioData is ready for Save Audio)
        if !accumulatedPCMData.isEmpty {
            if let m4aData = await convertPCMToM4A(accumulatedPCMData) {
                lastAudioData = m4aData
                dprint("ElevenLabs TTS: Converted to M4A, size: \(m4aData.count) bytes")

            }
            // Clear accumulated PCM data to free memory (M4A is now stored in lastAudioData)
            accumulatedPCMData = Data()
        }
    }

    /// Non-streaming playback - waits for full audio before playing
    private func speakNonStreaming(text: String, apiKey: String) async throws {
        // Prepare text for highlighting
        playbackController.prepareText(text)

        // Build API request
        let voiceId = selectedVoice.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : selectedVoice
        let urlString = "\(endpoint)/\(voiceId)?output_format=mp3_44100_128"
        guard let url = URL(string: urlString) else {
            throw TTSError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let modelId = selectedModel.isEmpty ? defaultModelId : selectedModel

        // Build voice_settings - add speed only when != 1.0 for Save Audio
        // ElevenLabs speed range is 0.7-1.2 (limited)
        var voiceSettings: [String: Any] = [
            "stability": 0.5,
            "similarity_boost": 0.75
        ]

        // Add speed for non-streaming (Save Audio) when speed != 1.0
        if abs(selectedSpeed - 1.0) > 0.01 {
            let elevenLabsSpeed = convertSpeedToElevenLabsRange(selectedSpeed)
            voiceSettings["speed"] = elevenLabsSpeed
        }

        var body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": voiceSettings
        ]

        // Add language_code only for models that support it (Turbo/Flash v2.5, Multilingual v2)
        // eleven_v3 and eleven_monolingual_v1 do NOT support language_code parameter
        let supportsLanguageCode = modelId.contains("v2") || modelId.contains("multilingual")
        if supportsLanguageCode,
           !selectedLanguage.isEmpty,
           let langCode = LanguageCode(rawValue: selectedLanguage),
           let elevenLabsCode = langCode.toElevenLabsTTSCode() {
            body["language_code"] = elevenLabsCode
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Perform request with retry logic for transient errors
        let (data, _) = try await TTSAPIHelper.performRequest(request, providerName: "ElevenLabs")

        // Store audio data for saving
        lastAudioData = data

        // Set initial playback rate from selectedSpeed
        playbackController.setPlaybackRate(Float(selectedSpeed))

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
        streamingPlayer.stop()
        playbackController.stopPlayback()
    }

    /// Set playback rate dynamically during playback (0.25 to 4.0)
    func setPlaybackRate(_ rate: Float) {
        if useStreamingMode {
            streamingPlayer.setPlaybackRate(rate)
        } else {
            playbackController.setPlaybackRate(rate)
        }
    }

    func clearAudioCache() {
        lastAudioData = nil
        accumulatedPCMData = Data()
    }

    /// Convert normalized speed (0.5-2.0) to ElevenLabs range (0.7-1.2)
    /// Used only for Save Audio (non-streaming) when speed != 1.0
    private func convertSpeedToElevenLabsRange(_ speed: Double) -> Double {
        // 0.5 -> 0.7, 1.0 -> 1.0, 2.0 -> 1.2
        let normalizedSpeed: Double
        if speed <= 1.0 {
            // Map 0.5-1.0 to 0.7-1.0
            normalizedSpeed = 0.7 + (speed - 0.5) * (0.3 / 0.5)
        } else {
            // Map 1.0-2.0 to 1.0-1.2
            normalizedSpeed = 1.0 + (speed - 1.0) * (0.2 / 1.0)
        }
        return max(0.7, min(1.2, normalizedSpeed))
    }

    func availableVoices() -> [TTSVoice] {
        // Return cached voices if available and not expired, otherwise return defaults
        if let cached = TTSVoiceCache.shared.getCachedVoices(for: .elevenLabs),
           !cached.isEmpty,
           !TTSVoiceCache.shared.isCacheExpired(for: .elevenLabs) {
            return cached
        }
        return Self.defaultVoices
    }

    func availableModels() -> [TTSModelInfo] {
        [
            TTSModelInfo(id: "eleven_v3", name: "Eleven v3", description: "Latest, highest quality", isDefault: true),
            TTSModelInfo(id: "eleven_flash_v2_5", name: "Eleven Flash v2.5", description: "Fast, low latency"),
            TTSModelInfo(id: "eleven_multilingual_v2", name: "Eleven Multilingual v2", description: "High quality, multilingual"),
            TTSModelInfo(id: "eleven_turbo_v2_5", name: "Eleven Turbo v2.5", description: "Fastest, optimized"),
            TTSModelInfo(id: "eleven_monolingual_v1", name: "Eleven Monolingual v1", description: "English only")
        ]
    }

    func speedRange() -> ClosedRange<Double> {
        // ElevenLabs speed range is approximately 0.5 to 2.0
        0.5...2.0
    }

    // MARK: - Voice Fetching

    /// Fetch voices from ElevenLabs API and update cache
    static func fetchAndCacheVoices() async {
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: .elevenLabs) else {
            dprint("ElevenLabs: No API key for voice fetching")

            return
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else {
            dprint("ElevenLabs: Invalid voices endpoint URL")

            return
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                dprint("ElevenLabs: Failed to fetch voices")

                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voicesArray = json["voices"] as? [[String: Any]] else {
                dprint("ElevenLabs: Invalid voices response format")

                return
            }

            var voices: [TTSVoice] = []
            for (index, voiceData) in voicesArray.enumerated() {
                guard let voiceId = voiceData["voice_id"] as? String,
                      let name = voiceData["name"] as? String else {
                    continue
                }

                // Get labels for language info
                var language = ""
                if let labels = voiceData["labels"] as? [String: Any] {
                    if let accent = labels["accent"] as? String {
                        language = accent
                    } else if let lang = labels["language"] as? String {
                        language = lang
                    }
                }

                voices.append(TTSVoice(
                    id: voiceId,
                    name: name,
                    language: language,
                    isDefault: index == 0
                ))
            }

            if !voices.isEmpty {
                await MainActor.run {
                    TTSVoiceCache.shared.cacheVoices(voices, for: .elevenLabs)
                }
                dprint("ElevenLabs: Cached \(voices.count) voices")

            }
        } catch {
            dprint("ElevenLabs: Error fetching voices: \(error)")

        }
    }

    /// Default voices as fallback
    private static let defaultVoices: [TTSVoice] = [
        TTSVoice(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", language: "american", isDefault: true),
        TTSVoice(id: "AZnzlk1XvdvUeBnXmlld", name: "Domi", language: "american"),
        TTSVoice(id: "EXAVITQu4vr4xnSDxMaL", name: "Bella", language: "american"),
        TTSVoice(id: "ErXwobaYiN019PkySvjV", name: "Antoni", language: "american"),
        TTSVoice(id: "MF3mGyEYCl7XYWbV9V6O", name: "Elli", language: "american"),
        TTSVoice(id: "TxGEqnHWrfWFTfGW9XjX", name: "Josh", language: "american"),
        TTSVoice(id: "VR6AewLTigWG4xSOukaG", name: "Arnold", language: "american"),
        TTSVoice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam", language: "american"),
        TTSVoice(id: "yoZ06aMxZJJ28mfd3POQ", name: "Sam", language: "american")
    ]

    // MARK: - Audio Conversion Helpers

    /// Convert PCM data to M4A (AAC) format for saving
    private func convertPCMToM4A(_ pcmData: Data) async -> Data? {
        // First convert PCM to WAV (add header) using shared utility
        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Then convert WAV to M4A using AudioConverter
        return await AudioConverter.convertToAAC(inputData: wavData, inputExtension: "wav")
    }
}
