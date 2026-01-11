import Foundation
@preconcurrency import AVFoundation

/// ElevenLabs TTS API implementation
@MainActor
final class ElevenLabsTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    var selectedVoice: String = "21m00Tcm4TlvDq8ikWAM"  // Default: Rachel
    var selectedModel: String = "eleven_v3"
    var selectedSpeed: Double = 1.0  // Speed multiplier (ElevenLabs range: 0.5-2.0)
    var selectedLanguage: String = ""  // "" = Auto (ElevenLabs uses language_code for Turbo/Flash v2.5)

    var supportsSpeedControl: Bool { true }

    private let apiKeyManager = APIKeyManager.shared
    private var audioPlayer: AVAudioPlayer?
    private var currentText = ""
    private var wordRanges: [NSRange] = []
    private var wordWeights: [Double] = []
    private var highlightTimer: Timer?

    private let endpoint = "https://api.elevenlabs.io/v1/text-to-speech"

    func speak(text: String) async throws {
        guard !text.isEmpty else {
            throw TTSError.noTextProvided
        }

        guard let apiKey = apiKeyManager.getAPIKey(for: .elevenLabs) else {
            throw TTSError.apiError("ElevenLabs API key not found")
        }

        stop()

        currentText = text
        wordRanges = calculateWordRanges(for: text)
        wordWeights = calculateWordWeights(for: text, ranges: wordRanges)

        // Request TTS from ElevenLabs
        let voiceId = selectedVoice.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : selectedVoice
        let urlString = "\(endpoint)/\(voiceId)?output_format=mp3_44100_128"
        var request = URLRequest(url: URL(string: urlString)!)
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

        // Save to temp file and play
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("tts_\(UUID().uuidString).mp3")
        try data.write(to: tempURL)

        audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()

        isSpeaking = true
        isPaused = false
        audioPlayer?.play()

        // Start highlight timer
        startHighlightTimer()

        // Clean up temp file after a delay
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    func pause() {
        if isSpeaking && !isPaused {
            audioPlayer?.pause()
            highlightTimer?.invalidate()
            isPaused = true
        }
    }

    func resume() {
        if isSpeaking && isPaused {
            audioPlayer?.play()
            startHighlightTimer()
            isPaused = false
        }
    }

    func stop() {
        highlightTimer?.invalidate()
        highlightTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        isPaused = false
        currentText = ""
        wordRanges = []
        wordWeights = []
    }

    private func calculateWordRanges(for text: String) -> [NSRange] {
        var ranges: [NSRange] = []

        let tokenizer = CFStringTokenizerCreate(
            nil,
            text as CFString,
            CFRangeMake(0, text.count),
            kCFStringTokenizerUnitWord,
            CFLocaleCopyCurrent()
        )

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            ranges.append(NSRange(location: range.location, length: range.length))
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        if ranges.isEmpty {
            var currentIndex = 0
            let components = text.components(separatedBy: .whitespacesAndNewlines)
            for component in components where !component.isEmpty {
                if let range = text.range(of: component, range: text.index(text.startIndex, offsetBy: currentIndex)..<text.endIndex) {
                    let nsRange = NSRange(range, in: text)
                    ranges.append(nsRange)
                    currentIndex = nsRange.upperBound
                }
            }
        }

        return ranges
    }

    private func calculateWordWeights(for text: String, ranges: [NSRange]) -> [Double] {
        guard !ranges.isEmpty else { return [] }

        let nsString = text as NSString
        var weights: [Double] = []

        let japaneseRange = text.range(of: "\\p{Script=Han}|\\p{Script=Hiragana}|\\p{Script=Katakana}", options: .regularExpression)
        let isJapanese = japaneseRange != nil

        for (index, range) in ranges.enumerated() {
            let word = nsString.substring(with: range)
            var weight: Double

            if isJapanese {
                let kanjiCount = word.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
                weight = Double(word.count) + Double(kanjiCount) * 0.2
            } else {
                let vowels = CharacterSet(charactersIn: "aeiouAEIOU")
                var syllables = 0
                var previousWasVowel = false

                for char in word.unicodeScalars {
                    let isVowel = vowels.contains(char)
                    if isVowel && !previousWasVowel {
                        syllables += 1
                    }
                    previousWasVowel = isVowel
                }
                weight = max(1.0, Double(syllables))
            }

            let endLocation = range.location + range.length
            if endLocation < nsString.length {
                let remainingLength = min(3, nsString.length - endLocation)
                let followingChars = nsString.substring(with: NSRange(location: endLocation, length: remainingLength))

                if followingChars.contains(where: { ".!?。！？\n".contains($0) }) {
                    weight += isJapanese ? 1.5 : 2.0
                } else if followingChars.contains(where: { ",;:、；：".contains($0) }) {
                    weight += isJapanese ? 0.8 : 1.0
                }
            }

            if index == ranges.count - 1 {
                weight += 0.5
            }

            weights.append(weight)
        }

        let totalWeight = weights.reduce(0, +)
        if totalWeight > 0 {
            weights = weights.map { $0 / totalWeight }
        }

        return weights
    }

    func availableVoices() -> [TTSVoice] {
        // Return cached voices if available, otherwise return defaults
        if let cached = TTSVoiceCache.shared.getCachedVoices(for: .elevenLabs), !cached.isEmpty {
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

    /// Fetch voices from ElevenLabs API and update cache
    static func fetchAndCacheVoices() async {
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: .elevenLabs) else {
            print("ElevenLabs: No API key for voice fetching")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("ElevenLabs: Failed to fetch voices")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voicesArray = json["voices"] as? [[String: Any]] else {
                print("ElevenLabs: Invalid voices response format")
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
                    isDefault: index == 0  // First voice is default
                ))
            }

            if !voices.isEmpty {
                await MainActor.run {
                    TTSVoiceCache.shared.cacheVoices(voices, for: .elevenLabs)
                }
                print("ElevenLabs: Cached \(voices.count) voices")
            }
        } catch {
            print("ElevenLabs: Error fetching voices: \(error)")
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

    private func startHighlightTimer() {
        guard let player = audioPlayer, player.duration > 0, !wordRanges.isEmpty, !wordWeights.isEmpty else { return }

        let updateInterval: TimeInterval = 0.03
        let lookAheadFraction: Double = 0.015

        highlightTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                guard let player = self.audioPlayer, self.isSpeaking, !self.isPaused else {
                    return
                }

                let progress = player.currentTime / player.duration
                let adjustedProgress = min(1.0, progress + lookAheadFraction)

                var cumulativeWeight: Double = 0
                var wordIndex = 0

                for (index, weight) in self.wordWeights.enumerated() {
                    cumulativeWeight += weight
                    if adjustedProgress <= cumulativeWeight {
                        wordIndex = index
                        break
                    }
                    wordIndex = index
                }

                if wordIndex >= 0 && wordIndex < self.wordRanges.count {
                    self.delegate?.tts(self, willSpeakRange: self.wordRanges[wordIndex], of: self.currentText)
                }
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension ElevenLabsTTS: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            highlightTimer?.invalidate()
            highlightTimer = nil
            isSpeaking = false
            isPaused = false
            delegate?.tts(self, didFinishSpeaking: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            highlightTimer?.invalidate()
            highlightTimer = nil
            isSpeaking = false
            isPaused = false
            if let error = error {
                delegate?.tts(self, didFailWithError: error)
            }
        }
    }
}
