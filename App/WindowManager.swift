import AppKit
import SwiftUI

/// Manages app windows (About, etc.) that need to be opened from outside SwiftUI scene context
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var aboutWindow: NSWindow?

    private init() {}

    func openAboutWindow() {
        // If window already exists and is visible, just bring it to front
        if let window = aboutWindow, window.isVisible {
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
            let settingsOpen = NSApp.windows.contains { $0.title == "Settings" && $0.isVisible }
            if !settingsOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
