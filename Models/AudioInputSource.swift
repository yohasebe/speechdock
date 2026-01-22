import Foundation
import ScreenCaptureKit

/// Represents the type of audio input source
enum AudioInputSourceType: String, CaseIterable, Codable, Identifiable {
    case microphone = "Microphone"
    case systemAudio = "System Audio"
    case applicationAudio = "App Audio"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.3.fill"
        case .applicationAudio: return "app.fill"
        }
    }

    var description: String {
        switch self {
        case .microphone:
            return "Record from microphone"
        case .systemAudio:
            return "Capture all system audio output"
        case .applicationAudio:
            return "Capture audio from a specific app"
        }
    }
}

/// Represents a specific audio input source configuration
struct AudioInputSource: Equatable, Identifiable {
    let type: AudioInputSourceType
    let applicationBundleID: String?  // Only for applicationAudio type
    let applicationName: String?      // Display name for the app

    var id: String {
        switch type {
        case .microphone, .systemAudio:
            return type.rawValue
        case .applicationAudio:
            return "app:\(applicationBundleID ?? "unknown")"
        }
    }

    var displayName: String {
        switch type {
        case .microphone:
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        case .applicationAudio:
            return applicationName ?? "App"
        }
    }

    var icon: String {
        type.icon
    }

    // Convenience initializers
    static let microphone = AudioInputSource(type: .microphone, applicationBundleID: nil, applicationName: nil)
    static let systemAudio = AudioInputSource(type: .systemAudio, applicationBundleID: nil, applicationName: nil)

    static func app(bundleID: String, name: String) -> AudioInputSource {
        AudioInputSource(type: .applicationAudio, applicationBundleID: bundleID, applicationName: name)
    }
}

/// Information about a running application that can be captured
struct CapturableApplication: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    let isRecentlyUsed: Bool

    var id: String { bundleID }

    init(bundleID: String, name: String, icon: NSImage?, isRecentlyUsed: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.isRecentlyUsed = isRecentlyUsed
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
    }

    static func == (lhs: CapturableApplication, rhs: CapturableApplication) -> Bool {
        lhs.bundleID == rhs.bundleID
    }
}
