import Foundation
import AVFoundation
import NaturalLanguage

/// macOS native TTS using the `say` command with AVAudioPlayer for accurate timing
/// First generates audio file, then plays it with precise word highlighting
final class MacOSTTS: NSObject, TTSService, @unchecked Sendable {
    weak var delegate: TTSDelegate?

    @MainActor
    private(set) var isSpeaking = false
    @MainActor
    private(set) var isPaused = false
    @MainActor
    var selectedVoice: String = ""
    @MainActor
    var selectedModel: String = ""  // macOS uses system default
    @MainActor
    var selectedSpeed: Double = 1.0  // Speed multiplier (1.0 = normal, default ~175 wpm)

    var supportsSpeedControl: Bool { true }

    private var audioPlayer: AVAudioPlayer?
    private var currentText = ""
    private var wordRanges: [NSRange] = []
    private var wordWeights: [Double] = []  // Relative weight of each word for timing
    private var highlightTimer: Timer?
    private var speechStartTime: Date?
    private var actualDuration: TimeInterval = 0
    private var pausedTime: TimeInterval = 0
    private var tempAudioFile: URL?

    override init() {
        super.init()
    }

    @MainActor
    func speak(text: String) async throws {
        guard !text.isEmpty else {
            throw TTSError.noTextProvided
        }

        // Stop any current speech
        stop()

        currentText = text
        isSpeaking = true
        isPaused = false

        // Auto-detect language for word weighting
        let detectedLanguage = detectLanguage(for: text)

        // Use selected voice or auto-detect based on language
        let voice: String?
        if !selectedVoice.isEmpty {
            voice = selectedVoice
        } else {
            voice = findBestVoice(for: detectedLanguage)
        }

        // Calculate word ranges and weights for highlighting
        wordRanges = calculateWordRanges(for: text)
        wordWeights = calculateWordWeights(for: text, ranges: wordRanges, language: detectedLanguage)

        // Generate audio file first to get actual duration
        let audioFile = FileManager.default.temporaryDirectory.appendingPathComponent("tts_audio_\(UUID().uuidString).aiff")
        tempAudioFile = audioFile

        // Write text to temp file
        let tempTextFile = FileManager.default.temporaryDirectory.appendingPathComponent("tts_text_\(UUID().uuidString).txt")
        try text.write(to: tempTextFile, atomically: true, encoding: .utf8)

        // Generate audio file using say command
        let generateProcess = Process()
        generateProcess.executableURL = URL(fileURLWithPath: "/usr/bin/say")

        var arguments: [String] = []
        if let voice = voice {
            arguments.append("-v")
            arguments.append(voice)
        }
        // Apply speed control: default is ~175 wpm, valid range ~50-500
        let baseRate = 175.0
        let rate = Int(baseRate * selectedSpeed)
        arguments.append("-r")
        arguments.append(String(rate))
        arguments.append("-o")
        arguments.append(audioFile.path)
        arguments.append("-f")
        arguments.append(tempTextFile.path)
        generateProcess.arguments = arguments

        try generateProcess.run()
        generateProcess.waitUntilExit()

        // Clean up text file
        try? FileManager.default.removeItem(at: tempTextFile)

        guard generateProcess.terminationStatus == 0 else {
            throw TTSError.audioError("Failed to generate audio file")
        }

        // Load and play the audio file
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: audioFile)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            actualDuration = audioPlayer?.duration ?? 0

            guard actualDuration > 0 else {
                throw TTSError.audioError("Audio file has zero duration")
            }

            speechStartTime = Date()
            startHighlightTimer()
            audioPlayer?.play()
        } catch {
            throw TTSError.audioError("Failed to play audio: \(error.localizedDescription)")
        }
    }

    @MainActor
    func pause() {
        guard isSpeaking, !isPaused, let player = audioPlayer else { return }

        player.pause()
        isPaused = true
        pausedTime = player.currentTime
        highlightTimer?.invalidate()
    }

    @MainActor
    func resume() {
        guard isSpeaking, isPaused, let player = audioPlayer else { return }

        // Adjust start time to account for paused duration
        if let startTime = speechStartTime {
            let pauseDuration = player.currentTime - pausedTime
            speechStartTime = startTime.addingTimeInterval(pauseDuration)
        }

        player.play()
        isPaused = false
        startHighlightTimer()
    }

    @MainActor
    func stop() {
        highlightTimer?.invalidate()
        highlightTimer = nil

        audioPlayer?.stop()
        audioPlayer = nil

        // Clean up temp audio file
        if let tempFile = tempAudioFile {
            try? FileManager.default.removeItem(at: tempFile)
            tempAudioFile = nil
        }

        isSpeaking = false
        isPaused = false
        currentText = ""
        wordRanges = []
        wordWeights = []
        speechStartTime = nil
        pausedTime = 0
    }

    /// Detect language from text using NaturalLanguage framework
    private func detectLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        if let language = recognizer.dominantLanguage {
            return language.rawValue
        }

        // Default to Japanese if detection fails and text contains Japanese characters
        if text.unicodeScalars.contains(where: { $0.value >= 0x3040 && $0.value <= 0x9FFF }) {
            return "ja"
        }

        return "en"
    }

    /// Find the best available voice name for the `say` command
    private func findBestVoice(for languageCode: String) -> String? {
        let voiceList = getAvailableVoices()

        let preferredVoices: [String: [String]]
        switch languageCode {
        case "ja":
            preferredVoices = ["ja": ["Kyoko", "Otoya"]]
        case "en":
            preferredVoices = ["en": ["Samantha", "Alex", "Daniel", "Karen"]]
        case "zh-Hans", "zh":
            preferredVoices = ["zh": ["Ting-Ting", "Mei-Jia"]]
        default:
            preferredVoices = [languageCode: []]
        }

        for (_, voices) in preferredVoices {
            for voice in voices {
                if voiceList.contains(where: { $0.lowercased().contains(voice.lowercased()) }) {
                    return voice
                }
            }
        }

        return nil
    }

    /// Get list of available voices from `say -v ?`
    private func getAvailableVoices() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.components(separatedBy: .newlines)
            }
        } catch {
            // Ignore errors
        }

        return []
    }

    private func calculateWordRanges(for text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let nsString = text as NSString

        // Use CFStringTokenizer for better Japanese support
        let tokenizer = CFStringTokenizerCreate(
            nil,
            text as CFString,
            CFRangeMake(0, nsString.length),
            kCFStringTokenizerUnitWord,
            CFLocaleCopyCurrent()
        )

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            ranges.append(NSRange(location: cfRange.location, length: cfRange.length))
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        // Fallback: split by whitespace if no tokens found
        if ranges.isEmpty {
            let pattern = "\\S+"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let fullRange = NSRange(location: 0, length: nsString.length)
                let matches = regex.matches(in: text, options: [], range: fullRange)
                for match in matches {
                    ranges.append(match.range)
                }
            }
        }

        return ranges
    }

    /// Calculate relative weights for each word based on character count and complexity
    /// Longer words take more time to speak
    private func calculateWordWeights(for text: String, ranges: [NSRange], language: String) -> [Double] {
        guard !ranges.isEmpty else { return [] }

        let nsString = text as NSString
        var weights: [Double] = []

        for range in ranges {
            let word = nsString.substring(with: range)
            var weight: Double

            if language == "ja" {
                // For Japanese, each character takes roughly equal time
                // But kanji might take slightly longer due to complexity
                let kanjiCount = word.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
                weight = Double(word.count) + Double(kanjiCount) * 0.2
            } else {
                // For English and other languages, weight by syllable approximation
                // Simple heuristic: count vowel groups
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

            weights.append(weight)
        }

        // Normalize weights so they sum to 1.0
        let totalWeight = weights.reduce(0, +)
        if totalWeight > 0 {
            weights = weights.map { $0 / totalWeight }
        }

        return weights
    }

    private func startHighlightTimer() {
        guard !wordRanges.isEmpty, actualDuration > 0 else { return }

        // Use a frequent timer to update highlighting smoothly
        let updateInterval: TimeInterval = 0.05  // 50ms updates

        highlightTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                guard self.isSpeaking, !self.isPaused,
                      let player = self.audioPlayer, player.isPlaying else {
                    return
                }

                let currentTime = player.currentTime
                let progress = currentTime / self.actualDuration

                // Find the word index based on weighted progress
                var cumulativeWeight: Double = 0
                var wordIndex = 0

                for (index, weight) in self.wordWeights.enumerated() {
                    cumulativeWeight += weight
                    if progress <= cumulativeWeight {
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

    // MARK: - Voice List

    @MainActor
    func availableVoices() -> [TTSVoice] {
        var voices: [TTSVoice] = []

        // Add auto-detect option
        voices.append(TTSVoice(id: "", name: "Auto (detect language)", language: "", isDefault: true))

        // Get available voices from `say -v ?`
        let voiceList = getAvailableVoices()

        for line in voiceList {
            // Parse voice line format: "Voice Name    language_code  # description"
            let parts = line.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !parts.isEmpty else { continue }

            // Extract voice name (everything before the language code)
            let components = parts.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 2 else { continue }

            // Language code is the last component before #
            let languageCode = components.last ?? ""

            // Voice name is everything except the last component
            let voiceName = components.dropLast().joined(separator: " ")

            guard !voiceName.isEmpty else { continue }

            voices.append(TTSVoice(
                id: voiceName,
                name: voiceName,
                language: languageCode,
                isDefault: false
            ))
        }

        return voices
    }

    @MainActor
    func availableModels() -> [TTSModelInfo] {
        [TTSModelInfo(id: "default", name: "System Default", description: "macOS built-in TTS", isDefault: true)]
    }

    @MainActor
    func speedRange() -> ClosedRange<Double> {
        // macOS say command supports ~50-500 wpm, base rate is 175
        // So valid multiplier range is roughly 0.3 to 2.5
        0.5...2.0
    }
}

// MARK: - AVAudioPlayerDelegate

extension MacOSTTS: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.highlightTimer?.invalidate()
            self.highlightTimer = nil

            // Clean up temp audio file
            if let tempFile = self.tempAudioFile {
                try? FileManager.default.removeItem(at: tempFile)
                self.tempAudioFile = nil
            }

            self.isSpeaking = false
            self.isPaused = false
            self.audioPlayer = nil
            self.delegate?.tts(self, didFinishSpeaking: flag)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.stop()
            if let error = error {
                self.delegate?.tts(self, didFailWithError: error)
            }
        }
    }
}
