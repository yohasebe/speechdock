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
    private var converterMixerNode: AVAudioMixerNode?
    private var timePitchNode: AVAudioUnitTimePitch?

    /// Current playback rate (0.25 to 4.0, default 1.0)
    private(set) var currentPlaybackRate: Float = 1.0

    /// PCM format for OpenAI TTS: 24kHz, 16-bit signed, mono, little-endian
    private let pcmFormat: AVAudioFormat

    /// Buffer for accumulating PCM data before conversion
    private var pendingData = Data()

    /// Minimum bytes before scheduling a buffer (to avoid too many small buffers)
    /// 24000 samples/sec * 2 bytes/sample * 0.1 sec = 4800 bytes (~100ms of audio)
    private let minBufferBytes = 4800

    /// Pre-roll buffer threshold: accumulate this much data before starting playback
    /// This prevents buffer underrun from network latency variations
    /// 24000 samples/sec * 2 bytes/sample * 0.4 sec = 19200 bytes (~400ms of audio)
    private let preRollBufferBytes = 19200

    /// Flag indicating whether pre-roll buffering is complete
    private var preRollComplete = false

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
        preRollComplete = false
        totalSamplesScheduled = 0

        // Setup audio engine with time pitch node for dynamic speed control
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let converterMixer = AVAudioMixerNode()  // Used for Int16 → Float32 conversion
        let timePitch = AVAudioUnitTimePitch()

        // Set initial playback rate
        timePitch.rate = currentPlaybackRate
        // Higher overlap values (3-32) improve audio quality for time stretching
        // Default is 8, using 16 for better voice quality during rate changes
        timePitch.overlap = 16

        engine.attach(player)
        engine.attach(converterMixer)
        engine.attach(timePitch)

        // Connect: player → converterMixer → timePitch → mainMixer
        // MixerNode automatically converts Int16 to Float32 which timePitch requires
        engine.connect(player, to: converterMixer, format: pcmFormat)
        engine.connect(converterMixer, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        // Set output device if specified
        if !outputDeviceUID.isEmpty {
            try setOutputDevice(uid: outputDeviceUID, for: engine)
        }

        try engine.start()
        player.play()

        audioEngine = engine
        playerNode = player
        converterMixerNode = converterMixer
        timePitchNode = timePitch
        state = .playing

        // Note: onPlaybackStarted is now called after pre-roll buffering completes
        // to ensure the "Generating Audio..." message stays visible until actual audio plays
    }

    /// Append PCM data chunk from streaming response
    func appendData(_ data: Data) {
        guard state == .playing || state == .paused else { return }

        pendingData.append(data)

        // Pre-roll buffering: wait until we have enough data before starting to schedule
        // This prevents buffer underrun from network latency variations
        if !preRollComplete {
            if pendingData.count >= preRollBufferBytes {
                preRollComplete = true
                dprint("StreamingAudioPlayer: Pre-roll complete, accumulated \(pendingData.count) bytes (~\(pendingData.count / 48)ms)")

                // Schedule all accumulated data in chunks
                while pendingData.count >= minBufferBytes {
                    let chunk = pendingData.prefix(minBufferBytes)
                    scheduleBuffer(from: Data(chunk))
                    pendingData.removeFirst(minBufferBytes)
                }
                // Notify that actual playback is starting (after pre-roll buffer is scheduled)
                onPlaybackStarted?()
            }
            return
        }

        // Normal buffering: schedule buffer if we have enough data
        if pendingData.count >= minBufferBytes {
            scheduleBuffer(from: pendingData)
            pendingData = Data()
        }
    }

    /// Signal that the stream has ended (no more data coming)
    func finishStream() {
        guard state == .playing || state == .paused else { return }

        streamEnded = true

        // If pre-roll wasn't complete (short audio), schedule all accumulated data now
        if !preRollComplete && !pendingData.isEmpty {
            dprint("StreamingAudioPlayer: Stream ended before pre-roll complete, scheduling \(pendingData.count) bytes")

            preRollComplete = true
            // Schedule in chunks
            while pendingData.count >= minBufferBytes {
                let chunk = pendingData.prefix(minBufferBytes)
                scheduleBuffer(from: Data(chunk))
                pendingData.removeFirst(minBufferBytes)
            }
            // Notify that actual playback is starting
            onPlaybackStarted?()
        }

        // Schedule any remaining data (less than minBufferBytes)
        if !pendingData.isEmpty {
            scheduleBuffer(from: pendingData)
            pendingData = Data()
        }

        // If no buffers were scheduled, or all buffers have already completed, finish immediately
        // This handles the race condition where buffer callbacks fire before finishStream() is called
        if scheduledBufferCount == 0 || completedBufferCount >= scheduledBufferCount {
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
        converterMixerNode = nil
        timePitchNode = nil
        audioEngine = nil

        pendingData = Data()
        scheduledBufferCount = 0
        completedBufferCount = 0
        streamEnded = false
        preRollComplete = false
        totalSamplesScheduled = 0

        state = .idle
    }

    /// Set playback rate dynamically (0.25 to 4.0)
    /// Can be called during playback for real-time speed adjustment
    func setPlaybackRate(_ rate: Float) {
        let clampedRate = max(0.25, min(4.0, rate))
        currentPlaybackRate = clampedRate
        timePitchNode?.rate = clampedRate
    }

    // MARK: - Private Methods

    /// Convert PCM data to AVAudioPCMBuffer and schedule on player node
    private func scheduleBuffer(from data: Data) {
        guard let player = playerNode, state == .playing || state == .paused else { return }

        // Calculate frame count (16-bit mono = 2 bytes per frame)
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            dprint("StreamingAudioPlayer: Failed to create buffer")

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
        converterMixerNode = nil
        timePitchNode = nil
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
