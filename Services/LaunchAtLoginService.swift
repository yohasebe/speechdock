import Foundation
import ServiceManagement

/// Service to manage launch at login functionality
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private init() {}

    /// Whether launch at login is currently enabled
    var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            } else {
                // Fallback for older macOS versions
                return false
            }
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("Failed to update launch at login: \(error)")
                }
            }
        }
    }

    /// Check if launch at login is available on this system
    var isAvailable: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    /// Get the current status as a human-readable string
    var statusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return "Enabled"
            case .notRegistered:
                return "Not registered"
            case .notFound:
                return "Not found"
            case .requiresApproval:
                return "Requires approval in System Settings"
            @unknown default:
                return "Unknown"
            }
        }
        return "Not available"
    }
}
