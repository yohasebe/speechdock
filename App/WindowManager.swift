import AppKit
import SwiftUI

/// Manages app windows (Settings) that need to be opened from outside SwiftUI scene context
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var settingsWindowObserver: NSObjectProtocol?

    /// Navigation state for settings window - allows navigating to a specific category
    let settingsNavigation = SettingsNavigation()

    private init() {}

    func openSettingsWindow(selectedCategory: SettingsCategory? = nil) {
        // Update category if specified
        if let category = selectedCategory {
            settingsNavigation.selectedCategory = category
        }

        // Show in Dock while Settings is open
        NSApp.setActivationPolicy(.regular)

        // If window already exists and is visible, just bring it to front
        if let window = settingsWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create new Settings window
        let settingsView = SettingsWindow(navigation: settingsNavigation)
            .environment(AppState.shared)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "SpeechDock Settings"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 700, height: 500))
        window.minSize = NSSize(width: 650, height: 450)
        window.center()

        // Remove previous observer if any
        if let observer = settingsWindowObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // Set up observer to hide from Dock when window closes
        settingsWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.settingsWindow = nil
                NSApp.setActivationPolicy(.accessory)
            }
        }

        // Disable automatic key view loop to prevent Liquid Glass focus ring
        window.autorecalculatesKeyViewLoop = false

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Clear first responder to remove initial focus ring
        DispatchQueue.main.async {
            window.makeFirstResponder(nil)
        }
    }

    /// Convenience method for backward compatibility
    func openAboutWindow() {
        openSettingsWindow(selectedCategory: .about)
    }
}
