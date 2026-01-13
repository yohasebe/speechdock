import Foundation
import AVFoundation
import FluidAudio

/// Voice Activity Detection service using FluidAudio's Silero VAD
@MainActor
final class VADService: ObservableObject {
    static let shared = VADService()

    private var vadManager: VadManager?
    private var isInitialized = false

    // VAD configuration
    private let vadThreshold: Float = 0.5  // Probability threshold for speech detection
    private let minSilenceDuration: TimeInterval = 1.5  // Seconds of silence to trigger segment commit

    // State tracking
    private var silenceStartTime: Date?
    private var isSpeaking = false

    // Streaming state for VAD
    private var streamState: VadStreamState?

    private init() {}

    /// Initialize VAD manager (call once before using)
    func initialize() async throws {
        guard !isInitialized else { return }

        do {
            let config = VadConfig(defaultThreshold: vadThreshold)
            vadManager = try await VadManager(config: config)
            streamState = await vadManager?.makeStreamState()
            isInitialized = true
            #if DEBUG
            print("VADService: Initialized with threshold \(vadThreshold)")
            #endif
        } catch {
            #if DEBUG
            print("VADService: Failed to initialize: \(error)")
            #endif
            throw error
        }
    }

    /// Reset state for new recording session
    func reset() {
        silenceStartTime = nil
        isSpeaking = false
        // Create new stream state for new session
        Task {
            streamState = await vadManager?.makeStreamState()
        }
    }

    /// Process audio samples and return speech detection result
    /// - Parameter samples: 16kHz mono Float32 samples (4096 samples = 256ms chunk)
    /// - Returns: VADResult indicating speech state and whether to commit segment
    func processSamples(_ samples: [Float]) async -> VADResult {
        guard let manager = vadManager, isInitialized, var state = streamState else {
            return VADResult(isSpeech: true, shouldCommitSegment: false)
        }

        do {
            let result = try await manager.processStreamingChunk(
                samples,
                state: state,
                config: .default,
                returnSeconds: true,
                timeResolution: 2
            )

            // Update stream state for next chunk
            streamState = result.state

            let isSpeech = result.probability >= vadThreshold

            #if DEBUG
            if isSpeech != isSpeaking {
                print("VADService: Speech state changed to \(isSpeech ? "speaking" : "silent") (prob: \(String(format: "%.2f", result.probability)))")
            }
            #endif

            // Track speech/silence transitions
            if isSpeech {
                isSpeaking = true
                silenceStartTime = nil
                return VADResult(isSpeech: true, shouldCommitSegment: false)
            } else {
                // Silence detected
                if isSpeaking {
                    // Just transitioned to silence
                    if silenceStartTime == nil {
                        silenceStartTime = Date()
                    }

                    // Check if silence duration exceeds threshold
                    if let startTime = silenceStartTime,
                       Date().timeIntervalSince(startTime) >= minSilenceDuration {
                        // Long enough silence - commit segment
                        isSpeaking = false
                        silenceStartTime = nil
                        return VADResult(isSpeech: false, shouldCommitSegment: true)
                    }
                }
                return VADResult(isSpeech: false, shouldCommitSegment: false)
            }
        } catch {
            #if DEBUG
            print("VADService: Processing error: \(error)")
            #endif
            // On error, assume speech to avoid losing audio
            return VADResult(isSpeech: true, shouldCommitSegment: false)
        }
    }

    /// Check if currently initialized
    var isReady: Bool {
        isInitialized && vadManager != nil
    }
}

/// Result of VAD processing
struct VADResult {
    /// Whether speech was detected in this chunk
    let isSpeech: Bool

    /// Whether enough silence has passed to commit the current segment
    let shouldCommitSegment: Bool
}
