import Foundation
@preconcurrency import AVFoundation

/// ElevenLabs TTS API implementation
@MainActor
final class ElevenLabsTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool { playbackController.isSpeaking }
    var isPaused: Bool { playbackController.isPaused }

    var selectedVoice: String = "21m00Tcm4TlvDq8ikWAM"  // Default: Rachel
    var selectedModel: String = "eleven_v3"
    var selectedSpeed: Double = 1.0  // Speed multiplier (ElevenLabs range: 0.5-2.0)
    var selectedLanguage: String = ""  // "" = Auto (ElevenLabs uses language_code for Turbo/Flash v2.5)
    var audioOutputDeviceUID: String = "" {
        didSet { playbackController.outputDeviceUID = audioOutputDeviceUID }
    }

    private(set) var lastAudioData: Data?
    var audioFileExtension: String { "mp3" }

    var supportsSpeedControl: Bool { true }

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()
    private let endpoint = "https://api.elevenlabs.io/v1/text-to-speech"

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

        guard let apiKey = apiKeyManager.getAPIKey(for: .elevenLabs) else {
            throw TTSError.apiError("ElevenLabs API key not found")
        }

        stop()

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

        let modelId = selectedModel.isEmpty ? "eleven_v3" : selectedModel

        // Convert normalized speed (0.5-2.0) to ElevenLabs range (0.7-1.2)
        // 0.5 -> 0.7, 1.0 -> 1.0, 2.0 -> 1.2
        let normalizedSpeed: Double
        if selectedSpeed <= 1.0 {
            // Map 0.5-1.0 to 0.7-1.0
            normalizedSpeed = 0.7 + (selectedSpeed - 0.5) * (0.3 / 0.5)
        } else {
            // Map 1.0-2.0 to 1.0-1.2
            normalizedSpeed = 1.0 + (selectedSpeed - 1.0) * (0.2 / 1.0)
        }
        let clampedSpeed = max(0.7, min(1.2, normalizedSpeed))

        var body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "speed": clampedSpeed
            ]
        ]

        // Add language_code if specified (for Turbo/Flash v2.5 models)
        if !selectedLanguage.isEmpty,
           let langCode = LanguageCode(rawValue: selectedLanguage),
           let elevenLabsCode = langCode.toElevenLabsTTSCode() {
            body["language_code"] = elevenLabsCode
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
            #if DEBUG
            print("ElevenLabs: No API key for voice fetching")
            #endif
            return
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else {
            #if DEBUG
            print("ElevenLabs: Invalid voices endpoint URL")
            #endif
            return
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                #if DEBUG
                print("ElevenLabs: Failed to fetch voices")
                #endif
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voicesArray = json["voices"] as? [[String: Any]] else {
                #if DEBUG
                print("ElevenLabs: Invalid voices response format")
                #endif
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
                #if DEBUG
                print("ElevenLabs: Cached \(voices.count) voices")
                #endif
            }
        } catch {
            #if DEBUG
            print("ElevenLabs: Error fetching voices: \(error)")
            #endif
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
}
