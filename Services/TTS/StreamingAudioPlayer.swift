import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Handles streaming PCM audio playback using AVAudioEngine
/// Designed for real-time TTS streaming where audio chunks arrive progressively
@MainActor
final class StreamingAudioPlayer {

    // MARK: - State

    enum State {
        case idle
        case playing
        case paused
        case finished
    }

    private(set) var state: State = .idle

    var isSpeaking: Bool { state == .playing }
    var isPaused: Bool { state == .paused }

    /// Audio output device UID (empty string = system default)
    var outputDeviceUID: String = ""

    // MARK: - Callbacks

    var onPlaybackStarted: (() -> Void)?
    var onPlaybackFinished: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Audio Engine Components

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// PCM format for OpenAI TTS: 24kHz, 16-bit signed, mono, little-endian
    private let pcmFormat: AVAudioFormat

    /// Buffer for accumulating PCM data before conversion
    private var pendingData = Data()

    /// Minimum bytes before scheduling a buffer (to avoid too many small buffers)
    /// 24000 samples/sec * 2 bytes/sample * 0.1 sec = 4800 bytes (~100ms of audio)
    private let minBufferBytes = 4800

    /// Track scheduled buffers for completion detection
    private var scheduledBufferCount = 0
    private var completedBufferCount = 0

    /// Flag indicating stream has ended (no more data coming)
    private var streamEnded = false

    /// Track total samples for progress calculation
    private var totalSamplesScheduled: Int64 = 0

    // MARK: - Initialization

    init() {
        // OpenAI PCM format: 24kHz, 16-bit signed integer, mono, little-endian
        // Note: AVAudioFormat uses native endianness, but OpenAI sends little-endian
        // On Apple Silicon (and Intel), native is little-endian, so this works directly
        pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true
        )!
    }

    // MARK: - Public Methods

    /// Start streaming playback - call before appending data
    func startStreaming() throws {
        guard state == .idle else {
            throw TTSError.audioError("Already streaming")
        }

        // Reset state
        pendingData = Data()
        scheduledBufferCount = 0
        completedBufferCount = 0
        streamEnded = false
        totalSamplesScheduled = 0

        // Setup audio engine
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)

        // Set output device if specified
        if !outputDeviceUID.isEmpty {
            try setOutputDevice(uid: outputDeviceUID, for: engine)
        }

        try engine.start()
        player.play()

        audioEngine = engine
        playerNode = player
        state = .playing

        onPlaybackStarted?()
    }

    /// Append PCM data chunk from streaming response
    func appendData(_ data: Data) {
        guard state == .playing || state == .paused else { return }

        pendingData.append(data)

        // Schedule buffer if we have enough data
        if pendingData.count >= minBufferBytes {
            scheduleBuffer(from: pendingData)
            pendingData = Data()
        }
    }

    /// Signal that the stream has ended (no more data coming)
    func finishStream() {
        guard state == .playing || state == .paused else { return }

        streamEnded = true

        // Schedule any remaining data
        if !pendingData.isEmpty {
            scheduleBuffer(from: pendingData)
            pendingData = Data()
        }

        // If no buffers were scheduled, finish immediately
        if scheduledBufferCount == 0 {
            handlePlaybackComplete()
        }
    }

    /// Pause playback
    func pause() {
        guard state == .playing else { return }
        playerNode?.pause()
        state = .paused
    }

    /// Resume playback
    func resume() {
        guard state == .paused else { return }
        playerNode?.play()
        state = .playing
    }

    /// Stop playback and cleanup
    func stop() {
        playerNode?.stop()
        audioEngine?.stop()

        playerNode = nil
        audioEngine = nil

        pendingData = Data()
        scheduledBufferCount = 0
        completedBufferCount = 0
        streamEnded = false
        totalSamplesScheduled = 0

        state = .idle
    }

    // MARK: - Private Methods

    /// Convert PCM data to AVAudioPCMBuffer and schedule on player node
    private func scheduleBuffer(from data: Data) {
        guard let player = playerNode, state == .playing || state == .paused else { return }

        // Calculate frame count (16-bit mono = 2 bytes per frame)
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            #if DEBUG
            print("StreamingAudioPlayer: Failed to create buffer")
            #endif
            return
        }

        buffer.frameLength = frameCount

        // Copy PCM data to buffer
        data.withUnsafeBytes { rawBufferPointer in
            guard let srcPtr = rawBufferPointer.baseAddress else { return }
            if let dstPtr = buffer.int16ChannelData?[0] {
                memcpy(dstPtr, srcPtr, data.count)
            }
        }

        scheduledBufferCount += 1
        totalSamplesScheduled += Int64(frameCount)

        // Schedule buffer with completion callback
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleBufferCompleted()
            }
        }
    }

    /// Called when a buffer finishes playing
    private func handleBufferCompleted() {
        completedBufferCount += 1

        // Check if all buffers have completed and stream has ended
        if streamEnded && completedBufferCount >= scheduledBufferCount {
            handlePlaybackComplete()
        }
    }

    /// Called when all playback is complete
    private func handlePlaybackComplete() {
        guard state != .idle && state != .finished else { return }

        state = .finished

        // Stop engine
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil

        onPlaybackFinished?(true)

        // Reset to idle for potential reuse
        state = .idle
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

    // MARK: - Progress Tracking

    /// Get current playback progress (0.0 to 1.0)
    /// Note: This is approximate for streaming since we don't know total duration upfront
    var currentPlaybackTime: TimeInterval {
        guard let player = playerNode,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
