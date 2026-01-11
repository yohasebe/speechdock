import Foundation
@preconcurrency import AVFoundation

/// Google Gemini TTS API implementation
@MainActor
final class GeminiTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    var selectedVoice: String = "Zephyr"  // Default voice
    var selectedModel: String = "gemini-2.5-flash-preview-tts"
    var selectedSpeed: Double = 1.0  // Speed multiplier (uses prompt-based control)
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects from text)

    var supportsSpeedControl: Bool { true }

    private let apiKeyManager = APIKeyManager.shared
    private var audioPlayer: AVAudioPlayer?
    private var currentText = ""
    private var wordRanges: [NSRange] = []
    private var wordWeights: [Double] = []
    private var highlightTimer: Timer?
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    func speak(text: String) async throws {
        guard !text.isEmpty else {
            throw TTSError.noTextProvided
        }

        guard let apiKey = apiKeyManager.getAPIKey(for: .gemini) else {
            throw TTSError.apiError("Gemini API key not found")
        }

        stop()

        currentText = text
        wordRanges = calculateWordRanges(for: text)
        wordWeights = calculateWordWeights(for: text, ranges: wordRanges)

        // Request TTS from Gemini
        let modelId = selectedModel.isEmpty ? "gemini-2.5-flash-preview-tts" : selectedModel
        let urlString = "\(baseURL)/\(modelId):generateContent?key=\(apiKey)"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // Validate voice - use default if invalid, and convert to lowercase
        let validVoice = Self.validVoiceIds.contains(selectedVoice) ? selectedVoice.lowercased() : "zephyr"

        // Prepend pace instruction to text (like monadic-chat does)
        let paceInstruction = paceInstructionForSpeed(selectedSpeed)
        let textWithPace = paceInstruction + text

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": textWithPace]
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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TTSError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let inlineData = firstPart["inlineData"] as? [String: Any],
              let base64Audio = inlineData["data"] as? String,
              let mimeType = inlineData["mimeType"] as? String else {
            throw TTSError.apiError("Invalid response format")
        }

        // Decode base64 audio
        guard let audioData = Data(base64Encoded: base64Audio) else {
            throw TTSError.audioError("Failed to decode audio data")
        }

        // Handle PCM audio (L16) by adding WAV header
        let finalAudioData: Data
        if mimeType.contains("L16") || mimeType.contains("pcm") {
            finalAudioData = createWAVFromPCM(audioData, mimeType: mimeType)
        } else {
            finalAudioData = audioData
        }

        // Save to temp file and play
        let ext = mimeType.contains("wav") || mimeType.contains("L16") || mimeType.contains("pcm") ? "wav" : "mp3"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("tts_\(UUID().uuidString).\(ext)")
        try finalAudioData.write(to: tempURL)

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

    private func createWAVFromPCM(_ pcmData: Data, mimeType: String) -> Data {
        // Extract sample rate from MIME type (e.g., "audio/L16;rate=24000")
        var sampleRate: UInt32 = 24000
        if let rateMatch = mimeType.range(of: "rate=") {
            let rateStart = mimeType.index(rateMatch.upperBound, offsetBy: 0)
            var rateEnd = rateStart
            while rateEnd < mimeType.endIndex && mimeType[rateEnd].isNumber {
                rateEnd = mimeType.index(after: rateEnd)
            }
            if let rate = UInt32(mimeType[rateStart..<rateEnd]) {
                sampleRate = rate
            }
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        var wavData = Data()

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // AudioFormat (PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data subchunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        wavData.append(pcmData)

        return wavData
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

    /// Valid Gemini voice IDs (lowercase)
    private static let validVoiceIds: Set<String> = [
        "zephyr", "puck", "charon", "kore", "fenrir", "aoede", "orus",
        "leda", "callirrhoe", "autonoe", "enceladus", "iapetus", "umbriel",
        "algieba", "despina", "erinome", "algenib", "rasalgethi", "laomedeia",
        "achernar", "alnilam", "schedar", "gacrux", "pulcherrima", "achird",
        "zubenelgenubi", "vindemiatrix", "sadachbia", "sadaltager", "sulafat"
    ]

    func availableVoices() -> [TTSVoice] {
        // Gemini TTS available voices (30 voices from monadic-chat)
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
        [
            TTSModelInfo(id: "gemini-2.5-flash-preview-tts", name: "Gemini 2.5 Flash TTS", description: "Fast, multilingual", isDefault: true),
            TTSModelInfo(id: "gemini-2.5-flash-lite-preview-tts", name: "Gemini 2.5 Flash Lite TTS", description: "Lightweight, faster"),
            TTSModelInfo(id: "gemini-2.0-flash-preview-tts", name: "Gemini 2.0 Flash TTS", description: "Previous generation")
        ]
    }

    func speedRange() -> ClosedRange<Double> {
        // Gemini uses prompt-based pace control
        // We map speed values to pace instructions
        0.5...2.0
    }

    /// Generate pace instruction for Gemini TTS based on speed setting
    /// Based on monadic-chat's implementation - always include a pace instruction
    private func paceInstructionForSpeed(_ speed: Double) -> String {
        // Map speed multiplier to natural language pace instruction
        // Always include instruction (even for normal speed) - this is key for Gemini TTS
        switch speed {
        case ..<0.6:
            return "Speak very slowly and deliberately. "
        case 0.6..<0.8:
            return "Speak slowly and take your time. "
        case 0.8..<0.95:
            return "Speak at a slightly slower pace than normal. "
        case 0.95..<1.15:
            // Normal speed - still include instruction
            return "Speak at a natural, conversational pace. "
        case 1.15..<1.4:
            return "Speak at a slightly faster pace than normal. "
        case 1.4..<1.8:
            return "Speak quickly and at a faster pace. "
        case 1.8...:
            return "[extremely fast] "
        default:
            return "Speak at a natural, conversational pace. "
        }
    }

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

extension GeminiTTS: AVAudioPlayerDelegate {
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
