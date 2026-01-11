import AppKit
import SwiftUI

/// Custom NSWindow that can become key window even when borderless
/// This allows text input in borderless floating windows
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FloatingWindowManager: ObservableObject {
    private var floatingWindow: NSWindow?
    private var previousApp: NSRunningApplication?
    @Published var isVisible = false

    func showFloatingWindow(
        appState: AppState,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        if floatingWindow == nil {
            createFloatingWindow()
        }

        let contentView = TranscriptionFloatingView(
            appState: appState,
            onConfirm: onConfirm,
            onCancel: onCancel
        )

        // Remember the currently active app before showing our window
        previousApp = NSWorkspace.shared.frontmostApplication

        floatingWindow?.contentView = NSHostingView(rootView: contentView)
        positionNearMouse()
        floatingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }

    private func createFloatingWindow() {
        floatingWindow = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        floatingWindow?.level = .floating
        floatingWindow?.isReleasedWhenClosed = false
        floatingWindow?.titlebarAppearsTransparent = true
        floatingWindow?.titleVisibility = .hidden
        floatingWindow?.backgroundColor = .clear
        floatingWindow?.isOpaque = false
        floatingWindow?.hasShadow = true
        floatingWindow?.isMovableByWindowBackground = true

        // Hide standard window buttons (traffic lights)
        floatingWindow?.standardWindowButton(.closeButton)?.isHidden = true
        floatingWindow?.standardWindowButton(.miniaturizeButton)?.isHidden = true
        floatingWindow?.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func positionNearMouse() {
        centerWindow()
    }

    private func centerWindow() {
        guard let window = floatingWindow,
              let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size

        // Center the window on screen
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.midY - windowSize.height / 2

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showTTSFloatingWindow(
        appState: AppState,
        onClose: @escaping () -> Void
    ) {
        // Close any existing window first
        floatingWindow?.orderOut(nil)
        floatingWindow = nil

        // Create resizable window for TTS that can accept keyboard input
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 400, height: 200)
        window.maxSize = NSSize(width: 900, height: 600)

        // Hide standard window buttons (traffic lights)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        floatingWindow = window

        let contentView = TTSFloatingView(
            appState: appState,
            onClose: onClose
        )

        // Remember the currently active app before showing our window
        previousApp = NSWorkspace.shared.frontmostApplication

        floatingWindow?.contentView = NSHostingView(rootView: contentView)
        positionNearMouse()
        floatingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }

    func hideFloatingWindow() {
        floatingWindow?.orderOut(nil)
        isVisible = false

        // Restore focus to the previous app
        if let previousApp = previousApp {
            previousApp.activate(options: [])
        }
        self.previousApp = nil
    }
}
