import Foundation
@preconcurrency import AVFoundation

/// OpenAI TTS API implementation
@MainActor
final class OpenAITTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    var selectedVoice: String = "alloy"
    var selectedModel: String = "gpt-4o-mini-tts"
    var selectedSpeed: Double = 1.0  // Speed multiplier (0.25-4.0 for tts-1/tts-1-hd)

    var supportsSpeedControl: Bool {
        // gpt-4o-mini-tts doesn't support speed parameter directly
        selectedModel != "gpt-4o-mini-tts"
    }

    private let apiKeyManager = APIKeyManager.shared
    private var audioPlayer: AVAudioPlayer?
    private var currentText = ""
    private var wordRanges: [NSRange] = []
    private var highlightTimer: Timer?

    private let endpoint = "https://api.openai.com/v1/audio/speech"

    func speak(text: String) async throws {
        guard !text.isEmpty else {
            throw TTSError.noTextProvided
        }

        guard let apiKey = apiKeyManager.getAPIKey(for: .openAI) else {
            throw TTSError.apiError("OpenAI API key not found")
        }

        stop()

        currentText = text
        wordRanges = calculateWordRanges(for: text)

        // Request TTS from OpenAI
        var request = URLRequest(url: URL(string: endpoint)!)
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
        // Note: gpt-4o-mini-tts doesn't support speed parameter
        if model != "gpt-4o-mini-tts" {
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
    }

    private func calculateWordRanges(for text: String) -> [NSRange] {
        var ranges: [NSRange] = []

        // Use CFStringTokenizer for better Japanese support
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

        // Fallback: split by whitespace if no tokens found
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
            TTSModelInfo(id: "gpt-4o-mini-tts", name: "GPT-4o Mini TTS", description: "Fast (no speed control)", isDefault: true),
            TTSModelInfo(id: "tts-1", name: "TTS-1", description: "Standard quality"),
            TTSModelInfo(id: "tts-1-hd", name: "TTS-1 HD", description: "High quality")
        ]
    }

    func speedRange() -> ClosedRange<Double> {
        // OpenAI TTS supports speed from 0.25 to 4.0
        // Note: gpt-4o-mini-tts doesn't support speed parameter
        0.25...4.0
    }

    private func startHighlightTimer() {
        guard let player = audioPlayer, player.duration > 0, !wordRanges.isEmpty else { return }

        let interval = player.duration / Double(wordRanges.count)

        highlightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                guard let player = self.audioPlayer, self.isSpeaking, !self.isPaused else {
                    timer.invalidate()
                    return
                }

                let progress = player.currentTime / player.duration
                let wordIndex = min(Int(progress * Double(self.wordRanges.count)), self.wordRanges.count - 1)

                if wordIndex >= 0 && wordIndex < self.wordRanges.count {
                    self.delegate?.tts(self, willSpeakRange: self.wordRanges[wordIndex], of: self.currentText)
                }
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension OpenAITTS: AVAudioPlayerDelegate {
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
