import Foundation
import AVFoundation
import NaturalLanguage
import CoreAudio

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
    @MainActor
    var selectedLanguage: String = ""  // "" = Auto (macOS uses voice-dependent language)
    @MainActor
    var audioOutputDeviceUID: String = ""  // "" = System Default

    /// Audio data from the last synthesis (M4A/AAC format, or AIFF if conversion fails)
    private(set) var lastAudioData: Data?

    /// Track the actual file extension of lastAudioData
    private var _audioFileExtension: String = "m4a"
    var audioFileExtension: String { _audioFileExtension }

    var supportsSpeedControl: Bool { true }

    /// MacOS TTS doesn't support streaming - always generates full audio first
    var useStreamingMode: Bool {
        get { false }
        set { /* Ignored - macOS TTS always uses full synthesis */ }
    }

    private var audioPlayer: AVAudioPlayer?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
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

        // Run process asynchronously to avoid blocking main thread
        let terminationStatus = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            generateProcess.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try generateProcess.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        // Clean up text file
        try? FileManager.default.removeItem(at: tempTextFile)

        guard terminationStatus == 0 else {
            throw TTSError.audioError("Failed to generate audio file")
        }

        // Convert AIFF to M4A (AAC) for smaller file size
        // Await conversion to ensure lastAudioData is ready (important for Save Audio)
        if let aiffData = try? Data(contentsOf: audioFile) {
            if let m4aData = await AudioConverter.convertToAAC(inputData: aiffData, inputExtension: "aiff") {
                lastAudioData = m4aData
                _audioFileExtension = "m4a"
            } else {
                // Fallback to AIFF if conversion fails
                lastAudioData = aiffData
                _audioFileExtension = "aiff"
            }
        }

        // Load and play the audio file
        do {
            // Use AVAudioEngine if custom output device is specified
            if !audioOutputDeviceUID.isEmpty {
                try playWithAudioEngine(url: audioFile)
            } else {
                try playWithAudioPlayer(url: audioFile)
            }
        } catch {
            throw TTSError.audioError("Failed to play audio: \(error.localizedDescription)")
        }
    }

    /// Play using AVAudioPlayer (system default output)
    @MainActor
    private func playWithAudioPlayer(url: URL) throws {
        audioPlayer = try AVAudioPlayer(contentsOf: url)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()
        actualDuration = audioPlayer?.duration ?? 0

        guard actualDuration > 0 else {
            throw TTSError.audioError("Audio file has zero duration")
        }

        speechStartTime = Date()
        startHighlightTimer()
        audioPlayer?.play()
    }

    /// Play using AVAudioEngine (supports custom output device)
    @MainActor
    private func playWithAudioEngine(url: URL) throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        engine.attach(playerNode)

        let file = try AVAudioFile(forReading: url)
        actualDuration = Double(file.length) / file.processingFormat.sampleRate

        guard actualDuration > 0 else {
            throw TTSError.audioError("Audio file has zero duration")
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)

        // Set output device
        try setOutputDevice(uid: audioOutputDeviceUID, for: engine)

        try engine.start()

        audioEngine = engine
        audioPlayerNode = playerNode

        // Schedule the entire file
        playerNode.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor in
                self?.audioEngineDidFinishPlaying()
            }
        }

        speechStartTime = Date()
        startHighlightTimer()
        playerNode.play()
    }

    /// Set the output device for an AVAudioEngine
    @MainActor
    private func setOutputDevice(uid: String, for engine: AVAudioEngine) throws {
        guard let device = AudioOutputManager.shared.device(withUID: uid) else {
            throw AudioOutputError.deviceNotFound
        }

        guard device.id != 0 else { return }  // System default, no need to set

        let outputNode = engine.outputNode
        guard let audioUnit = outputNode.audioUnit else {
            throw AudioOutputError.failedToSetDevice(0)
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioOutputError.failedToSetDevice(status)
        }
    }

    /// Called when AVAudioEngine finishes playing
    @MainActor
    private func audioEngineDidFinishPlaying() {
        highlightTimer?.invalidate()
        highlightTimer = nil
        stopAudioEngine()
        isSpeaking = false
        isPaused = false
        delegate?.tts(self, didFinishSpeaking: true)
    }

    /// Stop and clean up AVAudioEngine
    @MainActor
    private func stopAudioEngine() {
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioPlayerNode = nil
        audioEngine = nil
    }

    @MainActor
    func pause() {
        guard isSpeaking, !isPaused else { return }

        if audioEngine != nil {
            audioPlayerNode?.pause()
        } else if let player = audioPlayer {
            player.pause()
            pausedTime = player.currentTime
        }

        isPaused = true
        highlightTimer?.invalidate()
    }

    @MainActor
    func resume() {
        guard isSpeaking, isPaused else { return }

        if audioEngine != nil {
            audioPlayerNode?.play()
        } else if let player = audioPlayer {
            // Adjust start time to account for paused duration
            if let startTime = speechStartTime {
                let pauseDuration = player.currentTime - pausedTime
                speechStartTime = startTime.addingTimeInterval(pauseDuration)
            }
            player.play()
        }

        isPaused = false
        startHighlightTimer()
    }

    @MainActor
    func stop() {
        highlightTimer?.invalidate()
        highlightTimer = nil

        audioPlayer?.stop()
        audioPlayer = nil

        stopAudioEngine()

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

    func clearAudioCache() {
        lastAudioData = nil
        _audioFileExtension = "m4a"  // Reset to default
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

    /// Calculate relative weights for each word based on character count, complexity, and following punctuation
    /// Longer words and punctuation pauses take more time
    private func calculateWordWeights(for text: String, ranges: [NSRange], language: String) -> [Double] {
        guard !ranges.isEmpty else { return [] }

        let nsString = text as NSString
        var weights: [Double] = []

        for (index, range) in ranges.enumerated() {
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

            // Add extra weight for punctuation pauses after the word
            let endLocation = range.location + range.length
            if endLocation < nsString.length {
                // Check characters following this word for punctuation
                let remainingLength = min(3, nsString.length - endLocation)
                let followingChars = nsString.substring(with: NSRange(location: endLocation, length: remainingLength))

                // Long pause punctuation (period, question mark, exclamation, paragraph)
                if followingChars.contains(where: { ".!?。！？\n".contains($0) }) {
                    weight += language == "ja" ? 1.5 : 2.0
                }
                // Medium pause punctuation (comma, semicolon, colon)
                else if followingChars.contains(where: { ",;:、；：".contains($0) }) {
                    weight += language == "ja" ? 0.8 : 1.0
                }
            }

            // Add small pause weight for the last word (end of utterance)
            if index == ranges.count - 1 {
                weight += 0.5
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
        let updateInterval: TimeInterval = 0.03  // 30ms updates for smoother tracking

        // Look-ahead offset: highlight slightly before audio (visual perception is faster)
        // This value represents what fraction of duration to look ahead
        let lookAheadFraction: Double = 0.015  // ~1.5% look-ahead

        highlightTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] timer in
            // Check self synchronously first to invalidate timer immediately if deallocated
            guard self != nil else {
                timer.invalidate()
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                guard self.isSpeaking, !self.isPaused,
                      let player = self.audioPlayer, player.isPlaying else {
                    return
                }

                let currentTime = player.currentTime
                // Add look-ahead offset to show highlight slightly before the word is spoken
                let adjustedProgress = min(1.0, (currentTime / self.actualDuration) + lookAheadFraction)

                // Find the word index based on weighted progress
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

    // MARK: - Voice List

    @MainActor
    func availableVoices() -> [TTSVoice] {
        // Return cached voices if available and not expired
        if let cached = TTSVoiceCache.shared.getCachedVoices(for: .macOS),
           !cached.isEmpty,
           !TTSVoiceCache.shared.isCacheExpired(for: .macOS) {
            return cached
        }

        // Fetch and cache voices
        let voices = fetchVoicesFromSystem()
        TTSVoiceCache.shared.cacheVoices(voices, for: .macOS)
        return voices
    }

    /// Fetch voices from system using AVSpeechSynthesisVoice API
    @MainActor
    private func fetchVoicesFromSystem() -> [TTSVoice] {
        var voices: [TTSVoice] = []

        // Add auto-detect option
        voices.append(TTSVoice(id: "", name: "Auto (detect language)", language: "", isDefault: true, quality: .standard))

        // Get available voices from AVSpeechSynthesisVoice API
        let systemVoices = AVSpeechSynthesisVoice.speechVoices()

        for voice in systemVoices {
            // Map AVSpeechSynthesisVoiceQuality to our VoiceQuality
            let quality: VoiceQuality
            switch voice.quality {
            case .premium:
                quality = .premium
            case .enhanced:
                quality = .enhanced
            default:
                quality = .standard
            }

            // Extract voice name for say command (identifier format: com.apple.voice.compact.ja-JP.Kyoko)
            // The voice name for say command is the last component
            let voiceName = voice.name

            voices.append(TTSVoice(
                id: voiceName,
                name: voiceName,
                language: voice.language,
                isDefault: false,
                quality: quality
            ))
        }

        // Sort by quality (premium first), then by language, then by name
        voices = [voices[0]] + voices.dropFirst().sorted { lhs, rhs in
            if lhs.quality != rhs.quality {
                return lhs.quality > rhs.quality  // Higher quality first
            }
            if lhs.language != rhs.language {
                return lhs.language < rhs.language  // Alphabetical by language
            }
            return lhs.name < rhs.name  // Alphabetical by name
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
