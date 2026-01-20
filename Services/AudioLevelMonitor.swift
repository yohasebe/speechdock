import Foundation
import Combine

/// Monitors audio input levels for visualization and noise floor detection
@MainActor
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    /// Current audio level (0.0 to 1.0)
    @Published private(set) var level: Float = 0.0

    /// Peak level with decay (0.0 to 1.0)
    @Published private(set) var peakLevel: Float = 0.0

    /// Estimated noise floor level (0.0 to 1.0)
    @Published private(set) var noiseFloor: Float = 0.0

    /// Whether audio is currently being monitored
    @Published private(set) var isActive: Bool = false

    // Smoothing parameters
    private let smoothingFactor: Float = 0.3  // Higher = more responsive
    private let peakDecayRate: Float = 0.95   // How fast peak decays

    // Noise floor tracking
    private var recentLevels: [Float] = []
    private let noiseFloorWindowSize = 50  // ~1 second at typical update rate
    private let noiseFloorPercentile: Float = 0.1  // Use 10th percentile as noise floor

    private init() {}

    /// Update the audio level from raw samples
    /// - Parameter samples: Audio samples (typically 16kHz mono float)
    /// This method is nonisolated to allow calling from audio callback threads,
    /// but dispatches the actual update to the main actor.
    nonisolated func updateLevel(from samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Calculate RMS (Root Mean Square) for more accurate level
        // Do the computation on the calling thread to avoid blocking main thread
        let sumOfSquares = samples.reduce(0.0) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))

        // Convert to decibels and normalize to 0-1 range
        // Typical speech is around -20dB to -6dB
        let db = 20 * log10(max(rms, 0.0001))
        let normalizedLevel = max(0, min(1, (db + 50) / 50))  // -50dB to 0dB range

        // Dispatch to main actor for UI updates
        Task { @MainActor in
            // Apply smoothing
            self.level = self.level * (1 - self.smoothingFactor) + normalizedLevel * self.smoothingFactor

            // Update peak with decay
            if self.level > self.peakLevel {
                self.peakLevel = self.level
            } else {
                self.peakLevel *= self.peakDecayRate
            }

            // Track noise floor (sliding window of recent levels)
            self.recentLevels.append(self.level)
            if self.recentLevels.count > self.noiseFloorWindowSize {
                self.recentLevels.removeFirst()
            }
            self.updateNoiseFloor()
        }
    }

    /// Update noise floor estimate based on recent levels
    private func updateNoiseFloor() {
        guard recentLevels.count >= 10 else { return }

        // Sort levels and take the lower percentile as noise floor
        let sorted = recentLevels.sorted()
        let index = Int(Float(sorted.count) * noiseFloorPercentile)
        noiseFloor = sorted[max(0, min(index, sorted.count - 1))]
    }

    /// Calculate recommended VAD threshold based on noise floor
    /// Returns a value between 0.25 and 0.75, rounded to 2 decimal places
    func recommendedVADThreshold() -> Double {
        // Base threshold + adjustment for noise
        // Higher noise floor = higher threshold needed
        let baseThreshold: Float = 0.4
        let noiseAdjustment = noiseFloor * 0.5  // Scale noise contribution
        let threshold = min(0.75, max(0.25, baseThreshold + noiseAdjustment))
        // Round to 2 decimal places to avoid API "max decimal places exceeded" error
        return (Double(threshold) * 100).rounded() / 100
    }

    /// Calculate recommended silence duration based on noise characteristics
    /// Returns milliseconds (300-800ms range)
    func recommendedSilenceDuration() -> Int {
        // Higher noise = need longer silence to confirm end of speech
        let baseDuration: Float = 400
        let noiseAdjustment = noiseFloor * 400  // Up to 400ms additional
        return Int(min(800, max(300, baseDuration + noiseAdjustment)))
    }

    /// Start monitoring
    func start() {
        isActive = true
        level = 0
        peakLevel = 0
        recentLevels.removeAll()
        noiseFloor = 0
    }

    /// Stop monitoring
    func stop() {
        isActive = false
        level = 0
        peakLevel = 0
        recentLevels.removeAll()
        noiseFloor = 0
    }

    /// Reset levels without changing active state
    func reset() {
        level = 0
        peakLevel = 0
        recentLevels.removeAll()
        noiseFloor = 0
    }
}
