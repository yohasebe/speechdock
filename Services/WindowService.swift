import AppKit
import CoreGraphics

/// Information about a window for selection
struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String
    let bounds: CGRect
    let isOnScreen: Bool
    var thumbnail: NSImage?
    var appIcon: NSImage?

    var displayName: String {
        if windowTitle.isEmpty || windowTitle == ownerName {
            return ownerName
        }
        // Truncate long titles
        let maxLength = 40
        let title = windowTitle.count > maxLength
            ? String(windowTitle.prefix(maxLength)) + "..."
            : windowTitle
        return "\(ownerName) - \(title)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}

/// Service for window management operations
@MainActor
final class WindowService {
    static let shared = WindowService()

    private init() {}

    /// Bundle IDs of apps that are not suitable for text insertion
    /// These are system utilities, media viewers, and other apps without text input
    private let excludedBundleIDs: Set<String> = [
        // System utilities
        "com.apple.systempreferences",      // System Preferences (older macOS)
        "com.apple.systemsettings",         // System Settings (Ventura+)
        "com.apple.ActivityMonitor",
        "com.apple.DiskUtility",
        "com.apple.DirectoryUtility",
        "com.apple.SystemProfiler",         // System Information
        "com.apple.Console",
        "com.apple.KeychainAccess",
        "com.apple.installer",
        "com.apple.MigrateAssistant",       // Migration Assistant
        "com.apple.Bluetooth-File-Exchange",
        "com.apple.ColorSyncUtility",
        "com.apple.DigitalColorMeter",
        "com.apple.grapher",
        "com.apple.screenshot.launcher",    // Screenshot
        "com.apple.ScreenSharing",
        "com.apple.VoiceOverUtility",
        "com.apple.MIDI-Audio-Setup",       // Audio MIDI Setup
        "com.apple.bootcampassistant",

        // Media and viewer apps (typically read-only or no text input)
        // Note: Preview is NOT excluded because it supports text annotations in PDFs
        "com.apple.Photos",
        "com.apple.PhotoBooth",
        "com.apple.Image-Capture",
        "com.apple.Music",
        "com.apple.TV",
        "com.apple.Podcasts",
        "com.apple.Books",
        "com.apple.QuickTimePlayerX",

        // Calculator and simple utilities
        "com.apple.calculator",

        // Finder and system UI
        "com.apple.finder",
        "com.apple.dock",

        // App Store and system apps
        "com.apple.AppStore",
        "com.apple.Stocks",
        "com.apple.Home",
        "com.apple.findmy",
        "com.apple.Maps",
        "com.apple.Weather",
        "com.apple.FaceTime",
    ]

    /// Get bundle ID for a process
    private func getBundleID(for pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        return app.bundleIdentifier
    }

    /// Get list of all visible windows (excluding SpeechDock's own windows)
    /// Note: Thumbnails are NOT generated here for performance. Call generateThumbnailAsync separately.
    func getAvailableWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        var windows: [WindowInfo] = []

        for windowDict in windowList {
            // Get window ID
            guard let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            // Get owner PID - try both Int32 and Int
            let ownerPID: pid_t
            if let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t {
                ownerPID = pid
            } else if let pid = windowDict[kCGWindowOwnerPID as String] as? Int {
                ownerPID = pid_t(pid)
            } else {
                continue
            }

            // Get owner name
            guard let ownerName = windowDict[kCGWindowOwnerName as String] as? String else {
                continue
            }

            // Get layer - try both Int and NSNumber
            let layer: Int
            if let l = windowDict[kCGWindowLayer as String] as? Int {
                layer = l
            } else if let l = windowDict[kCGWindowLayer as String] as? NSNumber {
                layer = l.intValue
            } else {
                layer = 0
            }

            // Skip our own app windows
            if ownerPID == currentPID {
                continue
            }

            // Skip system UI elements (menu bar, dock, etc.)
            if layer != 0 {
                continue
            }

            // Get bounds - handle CFDictionary properly
            guard let boundsRef = windowDict[kCGWindowBounds as String] as? CFDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsRef) else {
                continue
            }
            let bounds = rect

            // Skip windows that are too small (likely not real windows)
            if bounds.width < 100 || bounds.height < 100 {
                continue
            }

            let windowTitle = windowDict[kCGWindowName as String] as? String ?? ""
            let isOnScreen = windowDict[kCGWindowIsOnscreen as String] as? Bool ?? true

            // Skip system UI processes by name (these don't have bundle IDs)
            let skipProcessNames: Set<String> = ["Dock", "Window Server", "SystemUIServer", "Control Center", "Notification Center"]
            if skipProcessNames.contains(ownerName) {
                continue
            }

            // Skip apps by bundle ID (more reliable than app name)
            if let bundleID = getBundleID(for: ownerPID),
               excludedBundleIDs.contains(bundleID) {
                continue
            }

            // Skip windows that are likely not text input targets
            let skipWindowTitles: Set<String> = ["Desktop", "Trash"]
            if skipWindowTitles.contains(windowTitle) {
                continue
            }

            var windowInfo = WindowInfo(
                id: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                windowTitle: windowTitle,
                bounds: bounds,
                isOnScreen: isOnScreen,
                thumbnail: nil,
                appIcon: nil
            )

            // Get app icon (lightweight operation)
            if let app = NSRunningApplication(processIdentifier: ownerPID) {
                windowInfo.appIcon = app.icon
            }

            windows.append(windowInfo)
        }

        // Sort by app name, then window title
        windows.sort { ($0.ownerName, $0.windowTitle) < ($1.ownerName, $1.windowTitle) }

        return windows
    }

    /// Generate thumbnail for a specific window asynchronously
    /// Call this from a background task to avoid blocking main thread
    nonisolated func generateThumbnailAsync(for windowID: CGWindowID, bounds: CGRect) async -> NSImage? {
        // Run on a background thread
        return await Task.detached(priority: .userInitiated) {
            guard let cgImage = CGWindowListCreateImage(
                bounds,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .nominalResolution]
            ) else {
                return nil
            }

            // Scale down for thumbnail
            let maxSize: CGFloat = 200
            let scale = min(maxSize / bounds.width, maxSize / bounds.height, 1.0)
            let thumbnailSize = NSSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )

            let image = NSImage(cgImage: cgImage, size: thumbnailSize)
            return image
        }.value
    }

    /// Generate a thumbnail for a window
    private func generateThumbnail(for windowID: CGWindowID, bounds: CGRect) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            bounds,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            return nil
        }

        // Scale down for thumbnail
        let maxSize: CGFloat = 120
        let scale = min(maxSize / bounds.width, maxSize / bounds.height, 1.0)
        let thumbnailSize = NSSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )

        let image = NSImage(cgImage: cgImage, size: thumbnailSize)
        return image
    }

    /// Check if a window still exists
    /// Returns a tuple: (appExists: Bool, windowExists: Bool)
    func checkWindowExists(_ windowInfo: WindowInfo) -> (appExists: Bool, windowExists: Bool) {
        // Check if the application is still running
        guard let app = NSRunningApplication(processIdentifier: windowInfo.ownerPID),
              !app.isTerminated else {
            return (appExists: false, windowExists: false)
        }

        // Check if the window still exists
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return (appExists: true, windowExists: false)
        }

        let windowExists = windowList.contains { dict in
            guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID else {
                return false
            }
            return windowID == windowInfo.id
        }

        return (appExists: true, windowExists: windowExists)
    }

    /// Activate a window and bring it to front
    func activateWindow(_ windowInfo: WindowInfo) -> Bool {
        // Get the running application
        guard let app = NSRunningApplication(processIdentifier: windowInfo.ownerPID) else {
            return false
        }

        // Check if the window is minimized and unminiaturize it first
        unminiaturizeWindowIfNeeded(windowInfo)

        // Activate the app
        let activated = app.activate(options: [.activateIgnoringOtherApps])

        if activated {
            // Try to raise the specific window using Accessibility API
            raiseWindow(windowInfo)
        }

        return activated
    }

    /// Check if a window is minimized and unminiaturize it
    private func unminiaturizeWindowIfNeeded(_ windowInfo: WindowInfo) {
        let appElement = AXUIElementCreateApplication(windowInfo.ownerPID)

        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return
        }

        // Find and unminiaturize matching windows
        for window in windows {
            var titleValue: AnyObject?
            var minimizedValue: AnyObject?

            // Check if this window matches by title
            let titleMatches: Bool
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                titleMatches = (title == windowInfo.windowTitle || windowInfo.windowTitle.isEmpty)
            } else {
                titleMatches = windowInfo.windowTitle.isEmpty
            }

            if titleMatches {
                // Check if minimized
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                   let isMinimized = minimizedValue as? Bool,
                   isMinimized {
                    // Unminiaturize the window
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                }
                return
            }
        }
    }

    /// Raise a specific window using Accessibility API
    private func raiseWindow(_ windowInfo: WindowInfo) {
        let appElement = AXUIElementCreateApplication(windowInfo.ownerPID)

        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return
        }

        // Find the matching window by title
        for window in windows {
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String,
               title == windowInfo.windowTitle || windowInfo.windowTitle.isEmpty {
                // Raise the window
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }

        // If no match found, raise the first window
        if let firstWindow = windows.first {
            AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
        }
    }
}
