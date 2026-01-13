import AppKit
import SwiftUI

/// Manages app windows (About, Settings) that need to be opened from outside SwiftUI scene context
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var aboutWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private init() {}

    func openAboutWindow() {
        // Show in Dock while About is open
        NSApp.setActivationPolicy(.regular)

        // If window already exists and is visible, just bring it to front
        if let window = aboutWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create new About window
        let aboutView = AboutView()
        let hostingController = NSHostingController(rootView: aboutView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "About TypeTalk"
        window.identifier = NSUserInterfaceItemIdentifier("about")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        // Set up observer to hide from Dock when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.aboutWindow = nil
            // Hide from Dock when About closes (only if Settings is not open)
            let settingsOpen = self?.settingsWindow?.isVisible == true
            if !settingsOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        aboutWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func openSettingsWindow() {
        // Show in Dock while Settings is open
        NSApp.setActivationPolicy(.regular)

        // If window already exists and is visible, just bring it to front
        if let window = settingsWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create new Settings window
        let settingsView = SettingsWindow()
            .environment(AppState.shared)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        // Set up observer to hide from Dock when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
            // Hide from Dock when Settings closes (only if About is not open)
            let aboutOpen = self?.aboutWindow?.isVisible == true
            if !aboutOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
