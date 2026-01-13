import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Shared controller for TTS audio playback and word highlighting
/// Used by all TTS service implementations to eliminate code duplication
@MainActor
final class TTSAudioPlaybackController: NSObject {

    // MARK: - State

    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private var audioPlayer: AVAudioPlayer?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var currentText = ""
    private var wordRanges: [NSRange] = []
    private var wordWeights: [Double] = []
    private var highlightTimer: Timer?
    private var tempFileURL: URL?
    private var playbackStartTime: AVAudioTime?
    private var audioDuration: TimeInterval = 0

    /// Audio output device UID (empty string = system default)
    var outputDeviceUID: String = ""

    // MARK: - Callbacks

    var onWordHighlight: ((NSRange, String) -> Void)?
    var onFinishSpeaking: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Public Methods

    /// Prepare text for playback (calculates word ranges and weights)
    func prepareText(_ text: String) {
        currentText = text
        wordRanges = Self.calculateWordRanges(for: text)
        wordWeights = Self.calculateWordWeights(for: text, ranges: wordRanges)
    }

    /// Play audio data with the given file extension
    func playAudio(data: Data, fileExtension: String) throws {
        // Stop any existing playback
        stopPlayback()

        // Save to temp file
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_\(UUID().uuidString).\(fileExtension)")

        guard let tempURL = tempFileURL else {
            throw TTSError.audioError("Failed to create temp file URL")
        }

        try data.write(to: tempURL)

        // Use AVAudioEngine if custom output device is specified, otherwise use simpler AVAudioPlayer
        if !outputDeviceUID.isEmpty {
            try playWithAudioEngine(url: tempURL)
        } else {
            try playWithAudioPlayer(url: tempURL)
        }

        // Schedule temp file cleanup as safety net (in case stopPlayback is not called)
        let urlToClean = tempURL
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            try? FileManager.default.removeItem(at: urlToClean)
        }
    }

    /// Play audio using AVAudioPlayer (simple, uses system default output)
    private func playWithAudioPlayer(url: URL) throws {
        audioPlayer = try AVAudioPlayer(contentsOf: url)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()

        audioDuration = audioPlayer?.duration ?? 0
        isSpeaking = true
        isPaused = false
        audioPlayer?.play()

        startHighlightTimer()
    }

    /// Play audio using AVAudioEngine (supports custom output device)
    private func playWithAudioEngine(url: URL) throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        engine.attach(playerNode)

        let file = try AVAudioFile(forReading: url)
        audioDuration = Double(file.length) / file.processingFormat.sampleRate

        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)

        // Set output device if specified
        if !outputDeviceUID.isEmpty {
            try setOutputDevice(uid: outputDeviceUID, for: engine)
        }

        try engine.start()

        audioEngine = engine
        audioPlayerNode = playerNode
        audioFile = file

        // Schedule the entire file with .dataPlayedBack completion type
        // This ensures the handler is called when audio has actually finished playing through hardware
        playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.audioEngineDidFinishPlaying()
            }
        }

        isSpeaking = true
        isPaused = false
        playerNode.play()
        playbackStartTime = playerNode.lastRenderTime

        startHighlightTimerForEngine()
    }

    /// Set the output device for an AVAudioEngine
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
    private func audioEngineDidFinishPlaying() {
        highlightTimer?.invalidate()
        highlightTimer = nil
        stopAudioEngine()
        isSpeaking = false
        isPaused = false
        onFinishSpeaking?(true)
    }

    /// Stop and clean up AVAudioEngine
    private func stopAudioEngine() {
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioPlayerNode = nil
        audioEngine = nil
        audioFile = nil
        playbackStartTime = nil
    }

    /// Pause playback
    func pause() {
        guard isSpeaking, !isPaused else { return }

        if audioEngine != nil {
            audioPlayerNode?.pause()
        } else {
            audioPlayer?.pause()
        }

        highlightTimer?.invalidate()
        isPaused = true
    }

    /// Resume playback
    func resume() {
        guard isSpeaking, isPaused else { return }

        if audioEngine != nil {
            audioPlayerNode?.play()
            startHighlightTimerForEngine()
        } else {
            audioPlayer?.play()
            startHighlightTimer()
        }

        isPaused = false
    }

    /// Stop playback and reset state
    func stopPlayback() {
        highlightTimer?.invalidate()
        highlightTimer = nil

        // Stop AVAudioPlayer if in use
        audioPlayer?.stop()
        audioPlayer = nil

        // Stop AVAudioEngine if in use
        stopAudioEngine()

        // Clean up temp file immediately
        cleanupTempFile()

        isSpeaking = false
        isPaused = false
        currentText = ""
        wordRanges = []
        wordWeights = []
        audioDuration = 0
    }

    /// Clean up temporary audio file
    private func cleanupTempFile() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    // MARK: - Word Highlighting Timer

    private func startHighlightTimer() {
        guard let player = audioPlayer,
              player.duration > 0,
              !wordRanges.isEmpty,
              !wordWeights.isEmpty else { return }

        let updateInterval: TimeInterval = 0.03  // 30ms updates
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

                // Find word index based on weighted progress
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
                    self.onWordHighlight?(self.wordRanges[wordIndex], self.currentText)
                }
            }
        }
    }

    /// Start highlight timer for AVAudioEngine playback
    private func startHighlightTimerForEngine() {
        guard audioDuration > 0,
              !wordRanges.isEmpty,
              !wordWeights.isEmpty else { return }

        let updateInterval: TimeInterval = 0.03  // 30ms updates
        let lookAheadFraction: Double = 0.015

        highlightTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                guard let playerNode = self.audioPlayerNode,
                      self.isSpeaking,
                      !self.isPaused,
                      playerNode.isPlaying else {
                    return
                }

                // Calculate current playback time from player node
                guard let nodeTime = playerNode.lastRenderTime,
                      let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                    return
                }

                let currentTime = Double(playerTime.sampleTime) / playerTime.sampleRate
                let progress = currentTime / self.audioDuration
                let adjustedProgress = min(1.0, progress + lookAheadFraction)

                // Find word index based on weighted progress
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
                    self.onWordHighlight?(self.wordRanges[wordIndex], self.currentText)
                }
            }
        }
    }

    // MARK: - Static Text Analysis Methods

    /// Calculate word ranges for the given text
    /// Uses CFStringTokenizer for Japanese support with whitespace fallback
    static func calculateWordRanges(for text: String) -> [NSRange] {
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

    /// Calculate word weights for timing estimation
    /// Accounts for Japanese/English differences and punctuation pauses
    static func calculateWordWeights(for text: String, ranges: [NSRange]) -> [Double] {
        guard !ranges.isEmpty else { return [] }

        let nsString = text as NSString
        var weights: [Double] = []

        // Simple language detection
        let japaneseRange = text.range(of: "\\p{Script=Han}|\\p{Script=Hiragana}|\\p{Script=Katakana}", options: .regularExpression)
        let isJapanese = japaneseRange != nil

        for (index, range) in ranges.enumerated() {
            let word = nsString.substring(with: range)
            var weight: Double

            if isJapanese {
                let kanjiCount = word.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
                weight = Double(word.count) + Double(kanjiCount) * 0.2
            } else {
                // Syllable approximation for English
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

            // Add punctuation pause weights
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

        // Normalize weights
        let totalWeight = weights.reduce(0, +)
        if totalWeight > 0 {
            weights = weights.map { $0 / totalWeight }
        }

        return weights
    }
}

// MARK: - AVAudioPlayerDelegate

extension TTSAudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            highlightTimer?.invalidate()
            highlightTimer = nil
            isSpeaking = false
            isPaused = false
            onFinishSpeaking?(flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            highlightTimer?.invalidate()
            highlightTimer = nil
            isSpeaking = false
            isPaused = false
            if let error = error {
                onError?(error)
            }
        }
    }
}
