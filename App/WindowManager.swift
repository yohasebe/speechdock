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

        // If window already exists and is visible, just bring it to front
        if let window = settingsWindow, window.isVisible {
            ActivationPolicyCoordinator.shared.windowWillShow(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create new Settings window
        let settingsView = SettingsWindow(navigation: settingsNavigation)
            .environment(AppState.shared)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = NSLocalizedString("SpeechDock Settings", comment: "Settings window")
        window.identifier = WindowLevelCoordinator.settingsIdentifier
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 700, height: 500))
        window.minSize = NSSize(width: 700, height: 450)  // Same as SettingsWindow's minWidth
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
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                if let window { ActivationPolicyCoordinator.shared.windowDidHide(window) }
                if self?.settingsWindow === window { self?.settingsWindow = nil }
            }
        }

        // Preserve keyboard navigation; only clear initial focus below.
        window.autorecalculatesKeyViewLoop = true

        settingsWindow = window
        ActivationPolicyCoordinator.shared.windowWillShow(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Clear first responder to remove initial focus ring
        DispatchQueue.main.async {
            window.makeFirstResponder(nil)
        }
    }

    /// Whether the settings window is currently visible
    var isSettingsWindowVisible: Bool {
        settingsWindow?.isVisible ?? false
    }

    /// Close the settings window
    func closeSettingsWindow() {
        settingsWindow?.close()
    }

    /// Convenience method for backward compatibility
    func openAboutWindow() {
        openSettingsWindow(selectedCategory: .about)
    }
}
