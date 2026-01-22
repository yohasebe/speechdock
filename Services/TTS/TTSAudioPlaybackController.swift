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
    private var timePitchNode: AVAudioUnitTimePitch?
    private var audioFile: AVAudioFile?

    /// Current playback rate (0.25 to 4.0, default 1.0)
    private(set) var currentPlaybackRate: Float = 1.0
    private var currentText = ""
    private var wordRanges: [NSRange] = []
    private var highlightTimer: Timer?
    private var tempFileURL: URL?
    private var playbackStartTime: AVAudioTime?
    private var audioDuration: TimeInterval = 0

    /// Audio output device UID (empty string = system default)
    var outputDeviceUID: String = ""

    // MARK: - Callbacks

    var onPlaybackStarted: (() -> Void)?
    var onWordHighlight: ((NSRange, String) -> Void)?
    var onFinishSpeaking: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Public Methods

    /// Prepare text for playback (calculates word ranges)
    func prepareText(_ text: String) {
        currentText = text
        wordRanges = Self.calculateWordRanges(for: text)
    }

    /// Play audio data with the given file extension
    func playAudio(data: Data, fileExtension: String) throws {
        // Stop any existing playback but preserve prepared text data
        highlightTimer?.invalidate()
        highlightTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        stopAudioEngine()
        cleanupTempFile()
        isSpeaking = false
        isPaused = false
        audioDuration = 0
        // Note: currentText, wordRanges are preserved from prepareText()

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
        audioPlayer?.enableRate = true
        audioPlayer?.rate = currentPlaybackRate
        audioPlayer?.prepareToPlay()

        audioDuration = audioPlayer?.duration ?? 0
        isSpeaking = true
        isPaused = false
        audioPlayer?.play()

        // Notify that playback has started
        onPlaybackStarted?()

        startHighlightTimer()
    }

    /// Play audio using AVAudioEngine (supports custom output device)
    private func playWithAudioEngine(url: URL) throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()

        // Set initial playback rate
        timePitch.rate = currentPlaybackRate

        engine.attach(playerNode)
        engine.attach(timePitch)

        let file = try AVAudioFile(forReading: url)
        audioDuration = Double(file.length) / file.processingFormat.sampleRate

        // Connect: playerNode → timePitch → mainMixer
        // Note: Use nil format for timePitch output to let the engine handle format conversion
        engine.connect(playerNode, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        // Set output device if specified
        if !outputDeviceUID.isEmpty {
            try setOutputDevice(uid: outputDeviceUID, for: engine)
        }

        try engine.start()

        audioEngine = engine
        audioPlayerNode = playerNode
        timePitchNode = timePitch
        audioFile = file

        // Schedule the entire file with .dataPlayedBack completion type
        playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.audioEngineDidFinishPlaying()
            }
        }

        isSpeaking = true
        isPaused = false
        playerNode.play()
        playbackStartTime = playerNode.lastRenderTime

        // Notify that playback has started
        onPlaybackStarted?()

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
        timePitchNode = nil
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

    /// Set playback rate dynamically (0.25 to 4.0)
    /// Can be called during playback for real-time speed adjustment
    func setPlaybackRate(_ rate: Float) {
        let clampedRate = max(0.25, min(4.0, rate))
        currentPlaybackRate = clampedRate

        // Update active playback
        if audioEngine != nil {
            timePitchNode?.rate = clampedRate
        } else if let player = audioPlayer {
            player.rate = clampedRate
        }
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
        audioDuration = 0
    }

    /// Clean up temporary audio file
    private func cleanupTempFile() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    // MARK: - Word Highlighting Timer (Simple linear progress)

    private func startHighlightTimer() {
        guard let player = audioPlayer,
              player.duration > 0,
              !wordRanges.isEmpty else { return }

        let updateInterval: TimeInterval = 0.05  // 50ms updates

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
                let wordIndex = Int(progress * Double(self.wordRanges.count))
                let clampedIndex = min(wordIndex, self.wordRanges.count - 1)

                if clampedIndex >= 0 {
                    self.onWordHighlight?(self.wordRanges[clampedIndex], self.currentText)
                }
            }
        }
    }

    /// Start highlight timer for AVAudioEngine playback
    private func startHighlightTimerForEngine() {
        guard audioDuration > 0,
              !wordRanges.isEmpty else { return }

        let updateInterval: TimeInterval = 0.05  // 50ms updates

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
                let wordIndex = Int(progress * Double(self.wordRanges.count))
                let clampedIndex = min(wordIndex, self.wordRanges.count - 1)

                if clampedIndex >= 0 {
                    self.onWordHighlight?(self.wordRanges[clampedIndex], self.currentText)
                }
            }
        }
    }

    // MARK: - Static Text Analysis Methods

    /// Calculate word ranges for the given text
    /// Simple whitespace-based splitting
    static func calculateWordRanges(for text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let nsString = text as NSString

        var currentIndex = 0
        let components = text.components(separatedBy: .whitespacesAndNewlines)

        for component in components where !component.isEmpty {
            if let range = text.range(of: component, range: text.index(text.startIndex, offsetBy: currentIndex)..<text.endIndex) {
                let nsRange = NSRange(range, in: text)
                ranges.append(nsRange)
                currentIndex = nsRange.upperBound
            }
        }

        return ranges
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
