import AppKit
import SwiftUI

/// Manages the subtitle overlay window lifecycle and updates
@MainActor
final class SubtitleOverlayManager {
    static let shared = SubtitleOverlayManager()

    private var overlayWindow: NSWindow?
    private weak var appState: AppState?
    private var isHiding = false
    private var windowMoveObserver: Any?
    private var currentScreenFrame: NSRect = .zero
    private var positionSaveTimer: Timer?

    /// Flag to prevent updatePosition() calls during drag
    private(set) var isDragging = false

    /// Window level for subtitle overlay (above most windows but below system UI)
    private static let subtitleWindowLevel = NSWindow.Level(rawValue: Int(NSWindow.Level.screenSaver.rawValue) - 1)

    private init() {}

    /// Show the subtitle overlay on the specified screen
    /// - Parameter screen: The screen to show the overlay on. If nil, uses main screen.
    func show(appState: AppState, on screen: NSScreen? = nil) {
        self.appState = appState

        // Hide existing window if any (without animation to avoid delays)
        if let existingWindow = overlayWindow {
            removeWindowMoveObserver()
            existingWindow.orderOut(nil)
            overlayWindow = nil
        }

        // Always use the main screen (where menu bar is displayed)
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen = targetScreen else { return }

        // Store current screen frame for position validation
        currentScreenFrame = targetScreen.frame

        // Calculate window frame
        let screenFrame = targetScreen.visibleFrame  // Use visibleFrame to account for menu bar and dock
        let windowWidth = min(screenFrame.width * 0.92, 1600)  // Cap max width
        // Calculate height based on max lines + header + padding
        let lineHeight = appState.subtitleFontSize * 1.4
        let textAreaHeight = lineHeight * CGFloat(appState.subtitleMaxLines)
        let windowHeight = textAreaHeight + 80  // header + padding
        var windowFrame: NSRect

        if appState.subtitleUseCustomPosition {
            // Use saved custom position, but validate it's within current screen bounds
            var x = appState.subtitleCustomX
            var y = appState.subtitleCustomY

            // Ensure the window is within screen bounds
            let fullScreenFrame = targetScreen.frame
            x = max(fullScreenFrame.minX, min(x, fullScreenFrame.maxX - windowWidth))
            y = max(fullScreenFrame.minY, min(y, fullScreenFrame.maxY - windowHeight))

            windowFrame = NSRect(
                x: x,
                y: y,
                width: windowWidth,
                height: windowHeight
            )
        } else if appState.subtitlePosition == .top {
            windowFrame = NSRect(
                x: screenFrame.origin.x + (screenFrame.width - windowWidth) / 2,
                y: screenFrame.maxY - windowHeight - 20,
                width: windowWidth,
                height: windowHeight
            )
        } else {
            windowFrame = NSRect(
                x: screenFrame.origin.x + (screenFrame.width - windowWidth) / 2,
                y: screenFrame.origin.y + 20,
                width: windowWidth,
                height: windowHeight
            )
        }

        #if DEBUG
        print("SubtitleOverlayManager: Screen frame: \(targetScreen.frame), visible: \(screenFrame)")
        print("SubtitleOverlayManager: Window frame: \(windowFrame)")
        #endif

        // Create the overlay window
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Configure window properties
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = Self.subtitleWindowLevel
        window.ignoresMouseEvents = false  // Allow mouse interaction for dragging
        window.isMovableByWindowBackground = true  // Allow dragging by background
        window.hasShadow = false
        // Remove .stationary to allow free movement
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        // Set up SwiftUI content view
        let contentView = SubtitleOverlayView()
            .environment(appState)

        window.contentView = NSHostingView(rootView: contentView)
        window.orderFrontRegardless()

        self.overlayWindow = window

        // Observe window move events to save position
        setupWindowMoveObserver(for: window)

        #if DEBUG
        print("SubtitleOverlayManager: Overlay shown on screen: \(targetScreen.localizedName)")
        #endif
    }

    /// Hide the subtitle overlay
    func hide() {
        // Prevent re-entrant calls
        guard !isHiding else { return }
        isHiding = true

        // Remove observer
        removeWindowMoveObserver()

        // Capture window reference before clearing
        let windowToHide = overlayWindow
        overlayWindow = nil

        // Hide the window
        windowToHide?.orderOut(nil)

        isHiding = false

        #if DEBUG
        print("SubtitleOverlayManager: Overlay hidden")
        #endif
    }

    /// Update the overlay position (top/bottom or custom)
    func updatePosition() {
        guard let appState = appState, overlayWindow != nil else { return }
        // Recreate the window with new position
        show(appState: appState)
    }

    /// Check if overlay is currently visible
    var isVisible: Bool {
        overlayWindow?.isVisible ?? false
    }

    /// Reset to preset position (clear custom position)
    func resetToPresetPosition() {
        guard let appState = appState else { return }
        appState.subtitleUseCustomPosition = false
        updatePosition()
    }

    // MARK: - Private Methods

    private func setupWindowMoveObserver(for window: NSWindow) {
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.windowDidMove()
        }
    }

    private func removeWindowMoveObserver() {
        if let observer = windowMoveObserver {
            NotificationCenter.default.removeObserver(observer)
            windowMoveObserver = nil
        }
        cancelPendingSave()
        isDragging = false
    }

    private func windowDidMove() {
        guard let window = overlayWindow, let appState = appState else { return }

        // Mark as dragging to prevent updatePosition() calls
        isDragging = true

        // Cancel any pending save
        positionSaveTimer?.invalidate()

        // Debounce: save position after dragging stops (200ms delay)
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveWindowPosition()
            }
        }
    }

    private func saveWindowPosition() {
        guard let window = overlayWindow, let appState = appState else { return }

        // Save the position
        let frame = window.frame
        appState.subtitleCustomX = frame.origin.x
        appState.subtitleCustomY = frame.origin.y

        // Set custom position flag without triggering updatePosition
        if !appState.subtitleUseCustomPosition {
            appState.setCustomPositionFlag(true)
        }

        // Clear dragging flag
        isDragging = false

        #if DEBUG
        print("SubtitleOverlayManager: Position saved at (\(frame.origin.x), \(frame.origin.y))")
        #endif
    }

    private func cancelPendingSave() {
        positionSaveTimer?.invalidate()
        positionSaveTimer = nil
    }
}
