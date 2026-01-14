import AppKit
import SwiftUI

/// Custom NSWindow that can become key window even when borderless
/// This allows text input in borderless floating windows
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Result of validating paste destination
enum PasteDestinationStatus {
    case valid
    case appTerminated
    case windowClosed
}

@MainActor
final class FloatingWindowManager: ObservableObject {
    // MARK: - Window Dimension Constants
    // These dimensions are tuned for typical content size and screen real estate

    /// STT panel initial size (accommodates text area, window selector, and buttons)
    private static let sttWindowSize = NSSize(width: 540, height: 340)

    /// TTS panel initial size (slightly taller for text input and controls)
    private static let ttsWindowSize = NSSize(width: 540, height: 380)

    /// Minimum window size (ensures all controls remain visible)
    private static let windowMinSize = NSSize(width: 440, height: 200)

    /// Maximum window size (prevents overly large panels)
    private static let windowMaxSize = NSSize(width: 900, height: 600)

    // MARK: - Properties

    private var floatingWindow: NSWindow?
    private var previousApp: NSRunningApplication?
    @Published var isVisible = false
    private var windowBecameKeyObserver: NSObjectProtocol?
    private var windowWillCloseObserver: NSObjectProtocol?
    private var keyboardEventMonitor: Any?
    private var storedOnCancel: (() -> Void)?
    private var storedOnClose: (() -> Void)?

    /// Weak reference to AppState for stopping STT/TTS on window close
    private weak var currentAppState: AppState?

    /// List of available windows for insertion target
    @Published var availableWindows: [WindowInfo] = []
    /// Currently selected window for text insertion
    @Published var selectedWindow: WindowInfo?
    /// When true, only copy to clipboard without pasting to a window
    @Published var clipboardOnly: Bool = false

    /// Alert state for invalid paste destination
    @Published var showDestinationAlert: Bool = false
    @Published var destinationAlertMessage: String = ""

    func showFloatingWindow(
        appState: AppState,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        if floatingWindow == nil {
            createFloatingWindow()
        }

        // Store cancel callback and appState for use when window is closed externally
        storedOnCancel = onCancel
        currentAppState = appState

        let contentView = TranscriptionFloatingView(
            appState: appState,
            onConfirm: onConfirm,
            onCancel: onCancel
        )

        // Remember the currently active app before showing our window
        previousApp = NSWorkspace.shared.frontmostApplication

        // Get available windows and select the frontmost one by default
        refreshAvailableWindows()

        floatingWindow?.contentView = NSHostingView(rootView: contentView)
        positionNearMouse()

        // Set up observer to handle window close (stop recording if active)
        setupWindowCloseObserver()

        // Become regular app to ensure proper window activation
        // This is essential for accessory apps to receive keyboard focus
        NSApp.setActivationPolicy(.regular)

        // Activate app first, then show window
        NSApp.activate(ignoringOtherApps: true)

        // Show window and bring to front
        floatingWindow?.orderFrontRegardless()
        floatingWindow?.makeKeyAndOrderFront(nil)
        isVisible = true

        // Activate window with retry (needed for apps launched via `open` command)
        activateWindowWithRetry()

        // Set up Cmd+W keyboard shortcut handler (SwiftUI shortcuts don't work in borderless windows)
        setupKeyboardEventMonitor()
    }

    /// Refresh the list of available windows
    func refreshAvailableWindows() {
        var windows = WindowService.shared.getAvailableWindows()

        // Sort so that the previous app's windows are at the top
        if let previousApp = previousApp {
            let previousPID = previousApp.processIdentifier
            windows.sort { w1, w2 in
                let w1IsPrevious = w1.ownerPID == previousPID
                let w2IsPrevious = w2.ownerPID == previousPID
                if w1IsPrevious && !w2IsPrevious {
                    return true
                } else if !w1IsPrevious && w2IsPrevious {
                    return false
                } else {
                    // Both same priority, sort by app name then window title
                    return (w1.ownerName, w1.windowTitle) < (w2.ownerName, w2.windowTitle)
                }
            }
        }

        availableWindows = windows

        // Keep current selection if it still exists in the list, otherwise select first
        if !clipboardOnly {
            if let current = selectedWindow,
               availableWindows.contains(where: { $0.id == current.id }) {
                // Current selection still valid, keep it
            } else {
                // Select first window only if no valid selection exists
                selectedWindow = availableWindows.first
            }
        }

        // Start loading thumbnails asynchronously
        loadThumbnailsAsync()
    }

    /// Load thumbnails for all available windows asynchronously
    private func loadThumbnailsAsync() {
        for (index, window) in availableWindows.enumerated() {
            // Skip if thumbnail already loaded
            guard window.thumbnail == nil else { continue }

            Task {
                let thumbnail = await WindowService.shared.generateThumbnailAsync(
                    for: window.id,
                    bounds: window.bounds
                )
                // Update on main thread
                await MainActor.run {
                    // Check if window still exists at this index
                    guard index < self.availableWindows.count,
                          self.availableWindows[index].id == window.id else { return }
                    self.availableWindows[index].thumbnail = thumbnail
                }
            }
        }
    }

    /// Load thumbnail for a specific window if not already loaded
    func loadThumbnailIfNeeded(for windowID: CGWindowID) {
        guard let index = availableWindows.firstIndex(where: { $0.id == windowID }),
              availableWindows[index].thumbnail == nil else { return }

        let window = availableWindows[index]
        Task {
            let thumbnail = await WindowService.shared.generateThumbnailAsync(
                for: window.id,
                bounds: window.bounds
            )
            await MainActor.run {
                // Check if window still exists at this index
                guard index < self.availableWindows.count,
                      self.availableWindows[index].id == windowID else { return }
                self.availableWindows[index].thumbnail = thumbnail
            }
        }
    }

    /// Select a specific window for text insertion
    func selectWindow(_ window: WindowInfo) {
        selectedWindow = window
        clipboardOnly = false
    }

    /// Select clipboard-only mode (no window paste)
    func selectClipboardOnly() {
        selectedWindow = nil
        clipboardOnly = true
    }

    /// Validate that the paste destination still exists
    /// Returns the status and shows alert if invalid
    func validatePasteDestination() -> PasteDestinationStatus {
        // Clipboard-only mode is always valid
        if clipboardOnly {
            return .valid
        }

        guard let window = selectedWindow else {
            return .valid
        }

        let (appExists, windowExists) = WindowService.shared.checkWindowExists(window)

        if !appExists {
            showDestinationUnavailableAlert(
                message: "The application \"\(window.ownerName)\" has been terminated. Please select another destination."
            )
            refreshAvailableWindows()
            return .appTerminated
        }

        if !windowExists {
            showDestinationUnavailableAlert(
                message: "The window \"\(window.displayName)\" has been closed. Please select another destination."
            )
            refreshAvailableWindows()
            return .windowClosed
        }

        return .valid
    }

    /// Show alert using NSAlert for immediate display
    private func showDestinationUnavailableAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Paste Destination Unavailable"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        // Show alert attached to floating window if available
        if let window = floatingWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    /// Dismiss the destination alert (kept for compatibility)
    func dismissDestinationAlert() {
        showDestinationAlert = false
        destinationAlertMessage = ""
    }

    private func createFloatingWindow() {
        floatingWindow = KeyableWindow(
            contentRect: NSRect(origin: .zero, size: Self.sttWindowSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // Use dynamic level (will be set when showing)
        floatingWindow?.level = WindowLevelCoordinator.shared.nextPanelLevel()
        floatingWindow?.isReleasedWhenClosed = false
        floatingWindow?.backgroundColor = .clear
        floatingWindow?.isOpaque = false
        floatingWindow?.hasShadow = true
        floatingWindow?.isMovableByWindowBackground = true
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
        // Store close callback and appState for use when window is closed externally
        storedOnClose = onClose
        currentAppState = appState

        // Close any existing window first
        floatingWindow?.orderOut(nil)
        floatingWindow = nil

        // Create resizable window for TTS that can accept keyboard input
        let window = KeyableWindow(
            contentRect: NSRect(origin: .zero, size: Self.ttsWindowSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // Use dynamic level (ensures this panel appears on top)
        window.level = WindowLevelCoordinator.shared.nextPanelLevel()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.minSize = Self.windowMinSize
        window.maxSize = Self.windowMaxSize

        floatingWindow = window

        let contentView = TTSFloatingView(
            appState: appState,
            onClose: onClose
        )

        // Remember the currently active app before showing our window
        previousApp = NSWorkspace.shared.frontmostApplication

        floatingWindow?.contentView = NSHostingView(rootView: contentView)
        positionNearMouse()

        // Set up observer to handle window close (stop TTS if active)
        setupWindowCloseObserver()

        // Become regular app to ensure proper window activation
        // This is essential for accessory apps to receive keyboard focus
        NSApp.setActivationPolicy(.regular)

        // Activate app first, then show window
        NSApp.activate(ignoringOtherApps: true)

        // Show window and bring to front
        floatingWindow?.orderFrontRegardless()
        floatingWindow?.makeKeyAndOrderFront(nil)
        isVisible = true

        // Set up observer to focus text view when window becomes key
        setupTextViewFocusObserver()

        // Activate window with retry (needed for apps launched via `open` command)
        activateWindowWithRetry()

        // Set up Cmd+W keyboard shortcut handler (SwiftUI shortcuts don't work in borderless windows)
        setupKeyboardEventMonitor()
    }

    /// Retry activation until window becomes key
    /// Apps launched via LaunchServices (`open` command) may need multiple attempts
    private func activateWindowWithRetry(attempt: Int = 0) {
        guard let window = floatingWindow, attempt < 20 else { return }

        if window.isKeyWindow { return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.activateWindowWithRetry(attempt: attempt + 1)
        }
    }

    /// Set up observer to focus text view when window becomes key
    private func setupTextViewFocusObserver() {
        // Remove any existing observer
        if let observer = windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowBecameKeyObserver = nil
        }

        guard let window = floatingWindow else { return }

        // Observe when window becomes key - this is when it can accept keyboard input
        windowBecameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self = self, let window = window else { return }

            // Remove observer after first trigger
            if let observer = self.windowBecameKeyObserver {
                NotificationCenter.default.removeObserver(observer)
                self.windowBecameKeyObserver = nil
            }

            // Find and focus the text view
            self.focusTextViewInWindow(window)
        }

        // If window is already key, focus immediately
        if window.isKeyWindow {
            if let observer = windowBecameKeyObserver {
                NotificationCenter.default.removeObserver(observer)
                windowBecameKeyObserver = nil
            }
            focusTextViewInWindow(window)
        }
    }

    /// Find NSTextView in window and make it first responder
    private func focusTextViewInWindow(_ window: NSWindow, attempt: Int = 0) {
        guard let contentView = window.contentView else { return }

        // Recursively find NSTextView
        func findTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView {
                return textView
            }
            for subview in view.subviews {
                if let found = findTextView(in: subview) {
                    return found
                }
            }
            return nil
        }

        if let textView = findTextView(in: contentView) {
            window.makeFirstResponder(textView)
        } else if attempt < 10 {
            // Retry if text view not found yet (SwiftUI might still be setting up)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                guard let window = window else { return }
                self?.focusTextViewInWindow(window, attempt: attempt + 1)
            }
        }
    }

    /// Set up observer to handle window close and stop STT/TTS if active
    private func setupWindowCloseObserver() {
        // Remove any existing observer
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowWillCloseObserver = nil
        }

        guard let window = floatingWindow else { return }

        // Observe when window will close - stop any active STT/TTS processing
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Stop STT recording if active
            if let onCancel = self.storedOnCancel {
                onCancel()
                self.storedOnCancel = nil
            }

            // Stop TTS playback if active
            if let onClose = self.storedOnClose {
                onClose()
                self.storedOnClose = nil
            }

            // Additional safety: directly stop via AppState
            if let appState = self.currentAppState {
                if appState.isRecording {
                    appState.cancelRecording()
                }
                if appState.ttsState == .speaking || appState.ttsState == .loading {
                    appState.stopTTS()
                }
            }
            self.currentAppState = nil
        }
    }

    /// Set up keyboard event monitor to handle Cmd+W for closing panels
    /// SwiftUI's .keyboardShortcut doesn't work reliably in borderless windows
    private func setupKeyboardEventMonitor() {
        // Remove any existing monitor
        removeKeyboardEventMonitor()

        keyboardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Check for Cmd+W (keyCode 13 = 'w')
            if event.modifierFlags.contains(.command) && event.keyCode == 13 {
                // Only handle if our window is key
                if self.floatingWindow?.isKeyWindow == true {
                    self.closePanel()
                    return nil  // Consume the event
                }
            }

            return event
        }
    }

    /// Remove the keyboard event monitor
    private func removeKeyboardEventMonitor() {
        if let monitor = keyboardEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardEventMonitor = nil
        }
    }

    /// Close the panel and stop any active STT/TTS processing
    func closePanel() {
        // Stop STT recording if active
        if let onCancel = storedOnCancel {
            onCancel()
        }

        // Stop TTS playback if active
        if let onClose = storedOnClose {
            onClose()
        }

        // Additional safety: directly stop via AppState
        if let appState = currentAppState {
            if appState.isRecording {
                appState.cancelRecording()
            }
            if appState.ttsState == .speaking || appState.ttsState == .loading {
                appState.stopTTS()
            }
        }

        // Hide the window
        hideFloatingWindow()
    }

    /// Bring the floating window to the front
    func bringToFront() {
        guard let window = floatingWindow else { return }

        // Ensure we're a regular app so we can become key
        NSApp.setActivationPolicy(.regular)

        // Update level to appear on top of other panels
        window.level = WindowLevelCoordinator.shared.nextPanelLevel()

        // Bring window to front
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // Activate app
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Temporarily hide the floating window (for showing save panels, etc.)
    func temporarilyHideWindow() {
        floatingWindow?.orderOut(nil)
    }

    /// Restore the floating window after temporarily hiding it
    func restoreWindow() {
        floatingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideFloatingWindow(skipActivation: Bool = false) {
        // Clean up observers
        if let observer = windowBecameKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            windowBecameKeyObserver = nil
        }
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowWillCloseObserver = nil
        }

        // Remove keyboard event monitor
        removeKeyboardEventMonitor()

        // Clear stored callbacks (already handled or not needed)
        storedOnCancel = nil
        storedOnClose = nil
        currentAppState = nil

        floatingWindow?.orderOut(nil)
        isVisible = false

        // Reset window level coordinator when panel is closed
        WindowLevelCoordinator.shared.reset()

        // Restore focus to the previous app (unless we already activated a selected window)
        if !skipActivation, let previousApp = previousApp {
            previousApp.activate(options: [])
        }
        self.previousApp = nil
        self.availableWindows = []
        self.selectedWindow = nil
        self.clipboardOnly = false

        // Return to accessory mode if no other windows are open
        let hasOtherWindows = NSApp.windows.contains {
            ($0.title == "Settings" || $0.identifier?.rawValue == "about") && $0.isVisible
        }
        if !hasOtherWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Activate the selected window and return success status
    func activateSelectedWindow() -> Bool {
        guard let window = selectedWindow else {
            // Fall back to previous app
            if let previousApp = previousApp {
                return previousApp.activate(options: [.activateIgnoringOtherApps])
            }
            return false
        }
        return WindowService.shared.activateWindow(window)
    }
}
