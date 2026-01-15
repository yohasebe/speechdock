import Foundation
import AppKit
import CoreGraphics

/// Service for capturing screen regions
enum ScreenCaptureService {

    /// Capture error types
    enum CaptureError: LocalizedError {
        case captureFailed
        case invalidRect
        case noScreensAvailable

        var errorDescription: String? {
            switch self {
            case .captureFailed:
                return "Failed to capture screen region"
            case .invalidRect:
                return "Invalid capture region specified"
            case .noScreensAvailable:
                return "No screens available for capture"
            }
        }
    }

    /// Capture a specific region of the screen
    /// - Parameters:
    ///   - rect: The rectangle to capture in screen coordinates (origin at bottom-left)
    ///   - excludingWindowIDs: Window IDs to exclude from capture (e.g., overlay windows)
    /// - Returns: Captured image as CGImage
    static func capture(rect: CGRect, excludingWindowIDs: [CGWindowID] = []) throws -> CGImage {
        guard rect.width >= 1 && rect.height >= 1 else {
            throw CaptureError.invalidRect
        }

        // Convert from bottom-left origin (AppKit) to top-left origin (CGImage)
        let screenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let flippedRect = CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        // Capture the screen region
        // Using kCGWindowListOptionOnScreenOnly to capture only visible content
        guard let image = CGWindowListCreateImage(
            flippedRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            throw CaptureError.captureFailed
        }

        return image
    }

    /// Capture a specific region, excluding specified windows
    /// - Parameters:
    ///   - rect: The rectangle to capture in screen coordinates
    ///   - excludingWindows: Windows to exclude from capture
    /// - Returns: Captured image as CGImage
    static func capture(rect: CGRect, excludingWindows: [NSWindow]) throws -> CGImage {
        guard rect.width >= 1 && rect.height >= 1 else {
            throw CaptureError.invalidRect
        }

        // Get screen height for coordinate conversion
        let screenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0

        // Convert from bottom-left origin (AppKit) to top-left origin (CGImage)
        let flippedRect = CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        // Get window IDs to exclude
        let excludeWindowIDs = excludingWindows.compactMap { window -> CGWindowID? in
            guard let windowNumber = window.windowNumber as? Int, windowNumber > 0 else {
                return nil
            }
            return CGWindowID(windowNumber)
        }

        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            throw CaptureError.captureFailed
        }

        // Filter out excluded windows and get remaining window IDs
        let windowIDs = windowList.compactMap { info -> CGWindowID? in
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else {
                return nil
            }
            if excludeWindowIDs.contains(windowID) {
                return nil
            }
            return windowID
        }

        // If we have windows to capture
        if !windowIDs.isEmpty {
            // Create image from specific windows (excluding our overlay)
            // We need to capture below a certain window level
            guard let image = CGWindowListCreateImage(
                flippedRect,
                .optionOnScreenBelowWindow,
                excludeWindowIDs.first ?? kCGNullWindowID,
                [.boundsIgnoreFraming, .nominalResolution]
            ) else {
                // Fallback to capturing all on-screen content
                guard let fallbackImage = CGWindowListCreateImage(
                    flippedRect,
                    .optionOnScreenOnly,
                    kCGNullWindowID,
                    [.boundsIgnoreFraming, .nominalResolution]
                ) else {
                    throw CaptureError.captureFailed
                }
                return fallbackImage
            }
            return image
        }

        throw CaptureError.captureFailed
    }

    /// Capture the entire screen (all displays combined)
    /// - Returns: Captured image as CGImage
    static func captureAllScreens() throws -> CGImage {
        guard !NSScreen.screens.isEmpty else {
            throw CaptureError.noScreensAvailable
        }

        // Get the bounding rect of all screens
        let allScreensRect = NSScreen.screens.reduce(CGRect.zero) { result, screen in
            result.union(screen.frame)
        }

        return try capture(rect: allScreensRect)
    }

    /// Check if screen recording permission is granted
    static var hasScreenRecordingPermission: Bool {
        // Attempt to capture a small region to check permission
        // This is a common technique to check screen recording permission
        let testRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let image = CGWindowListCreateImage(
            testRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .nominalResolution
        ) {
            // If we got an image with actual content, we have permission
            return image.width > 0 && image.height > 0
        }
        return false
    }

    /// Request screen recording permission by triggering a capture
    static func requestScreenRecordingPermission() {
        // Attempting to capture triggers the permission dialog
        _ = CGWindowListCreateImage(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            .optionOnScreenOnly,
            kCGNullWindowID,
            .nominalResolution
        )
    }
}
