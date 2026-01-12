import Foundation
@preconcurrency import AVFoundation

/// Shared controller for TTS audio playback and word highlighting
/// Used by all TTS service implementations to eliminate code duplication
@MainActor
final class TTSAudioPlaybackController: NSObject {

    // MARK: - State

    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private var audioPlayer: AVAudioPlayer?
    private var currentText = ""
    private var wordRanges: [NSRange] = []
    private var wordWeights: [Double] = []
    private var highlightTimer: Timer?
    private var tempFileURL: URL?

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

        audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()

        isSpeaking = true
        isPaused = false
        audioPlayer?.play()

        startHighlightTimer()

        // Schedule temp file cleanup
        let urlToClean = tempURL
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
            try? FileManager.default.removeItem(at: urlToClean)
        }
    }

    /// Pause playback
    func pause() {
        guard isSpeaking, !isPaused else { return }
        audioPlayer?.pause()
        highlightTimer?.invalidate()
        isPaused = true
    }

    /// Resume playback
    func resume() {
        guard isSpeaking, isPaused else { return }
        audioPlayer?.play()
        startHighlightTimer()
        isPaused = false
    }

    /// Stop playback and reset state
    func stopPlayback() {
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
