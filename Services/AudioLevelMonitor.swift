import Foundation
import Combine

/// Monitors audio input levels for visualization
@MainActor
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    /// Current audio level (0.0 to 1.0)
    @Published private(set) var level: Float = 0.0

    /// Peak level with decay (0.0 to 1.0)
    @Published private(set) var peakLevel: Float = 0.0

    /// Whether audio is currently being monitored
    @Published private(set) var isActive: Bool = false

    // Smoothing parameters
    private let smoothingFactor: Float = 0.3  // Higher = more responsive
    private let peakDecayRate: Float = 0.95   // How fast peak decays

    private init() {}

    /// Update the audio level from raw samples
    /// - Parameter samples: Audio samples (typically 16kHz mono float)
    func updateLevel(from samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Calculate RMS (Root Mean Square) for more accurate level
        let sumOfSquares = samples.reduce(0.0) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))

        // Convert to decibels and normalize to 0-1 range
        // Typical speech is around -20dB to -6dB
        let db = 20 * log10(max(rms, 0.0001))
        let normalizedLevel = max(0, min(1, (db + 50) / 50))  // -50dB to 0dB range

        // Apply smoothing
        level = level * (1 - smoothingFactor) + normalizedLevel * smoothingFactor

        // Update peak with decay
        if level > peakLevel {
            peakLevel = level
        } else {
            peakLevel *= peakDecayRate
        }
    }

    /// Start monitoring
    func start() {
        isActive = true
        level = 0
        peakLevel = 0
    }

    /// Stop monitoring
    func stop() {
        isActive = false
        level = 0
        peakLevel = 0
    }

    /// Reset levels without changing active state
    func reset() {
        level = 0
        peakLevel = 0
    }
}
