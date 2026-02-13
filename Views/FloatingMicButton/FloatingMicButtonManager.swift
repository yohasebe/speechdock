import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.speechdock", category: "FloatingMic")

// MARK: - Constants

/// Shared constants for the floating mic button and HUD
enum FloatingMicConstants {
    /// Size of the floating mic button
    static let buttonSize: CGFloat = 48

    /// Size of the HUD window
    static let hudWidth: CGFloat = 320
    static let hudHeight: CGFloat = 120

    /// HUD text display settings
    static let hudLineHeight: CGFloat = 20
    static let hudFontSize: CGFloat = 14
    static let hudMaxLines: Int = 4

    /// Margins and padding
    static let positionMargin: CGFloat = 16

    /// UserDefaults keys
    static let buttonPositionKey = "floatingMicButtonPosition"
    static let hudPositionKey = "floatingMicHUDPosition"

    /// Notification names
    static let transcriptionUpdatedNotification = Notification.Name("floatingMicTranscriptionUpdated")
}

/// A window that doesn't take focus when clicked
private class NonActivatingWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Manages the floating microphone button window for quick STT access
@MainActor
final class FloatingMicButtonManager {
    static let shared = FloatingMicButtonManager()

    private var buttonWindow: NSWindow?
    private weak var appState: AppState?
    private var positionSaveTimer: Timer?

    /// Partial text inserted via direct Accessibility API (for replacement on update)
    private(set) var lastInsertedPartialText: String = ""

    /// Whether we're using direct insertion mode for this session
    private(set) var isUsingDirectInsertion: Bool = false

    /// The app that was frontmost when recording started
    private var targetApp: NSRunningApplication?

    /// Last known frontmost app (excluding SpeechDock) - persists across show/hide cycles
    private var lastFrontmostApp: NSRunningApplication?

    /// Observer for app activation changes
    private var appActivationObserver: Any?

    /// Whether we've started global app tracking
    private var isTrackingApps = false

    /// Starting window position for drag
    private var dragStartOrigin: CGPoint?

    /// Starting mouse position for drag (in screen coordinates)
    private var dragStartMouseLocation: CGPoint?

    private let positionKey = FloatingMicConstants.buttonPositionKey
    private let buttonSize: CGFloat = FloatingMicConstants.buttonSize

    private init() {
        // Start tracking frontmost app immediately so we always know the last non-SpeechDock app
        startGlobalAppTracking()
    }

    deinit {
        // Clean up observer (for proper resource management, even though singleton won't deinit)
        // Note: We can safely remove the observer from any thread
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Start tracking frontmost app globally (called once at init)
    private func startGlobalAppTracking() {
        guard !isTrackingApps else { return }
        isTrackingApps = true

        // Initialize with current frontmost app if it's not SpeechDock
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastFrontmostApp = frontApp
        }

        // Observe app activations to always track the last frontmost app
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Use assumeIsolated since we're on the main queue
            MainActor.assumeIsolated {
                self?.handleAppActivation(notification)
            }
        }
    }

    /// Stop tracking frontmost app (for cleanup)
    private func stopGlobalAppTracking() {
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        isTrackingApps = false
    }

    // MARK: - Show/Hide

    var isVisible: Bool {
        buttonWindow != nil
    }

    func show(appState: AppState) {
        guard buttonWindow == nil else {
            logger.debug("show: buttonWindow already exists")
            return
        }

        self.appState = appState

        // Clear saved HUD position so it will appear near the button on first recording
        UserDefaults.standard.removeObject(forKey: FloatingMicConstants.hudPositionKey)

        let frame = savedFrameOrDefault()
        logger.debug("show: creating window at frame \(frame.debugDescription, privacy: .public)")

        let window = NonActivatingWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = WindowLevelCoordinator.shared.nextPanelLevel()
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false  // We handle drag manually
        window.hasShadow = false  // Shadow is on the view itself
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        let contentView = FloatingMicButtonView(appState: appState, manager: self)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.layer?.backgroundColor = .clear
        window.contentView = hostingView
        window.orderFrontRegardless()

        self.buttonWindow = window
        logger.debug("show: buttonWindow created and ordered front")
    }

    func hide() {
        saveWindowPosition()
        positionSaveTimer?.invalidate()
        positionSaveTimer = nil

        // Hide HUD if visible
        FloatingMicTextHUD.shared.hide()

        buttonWindow?.orderOut(nil)
        buttonWindow = nil
        appState = nil
        // Keep lastFrontmostApp for next show()

        WindowLevelCoordinator.shared.reset()
    }

    func toggle(appState: AppState) {
        if isVisible {
            hide()
        } else {
            show(appState: appState)
        }
    }

    // MARK: - Window Movement

    func startDragging() {
        guard let window = buttonWindow else { return }
        dragStartOrigin = window.frame.origin
        dragStartMouseLocation = NSEvent.mouseLocation
    }

    func continueDragging() {
        guard let window = buttonWindow,
              let startOrigin = dragStartOrigin,
              let startMouse = dragStartMouseLocation else { return }

        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - startMouse.x
        let deltaY = currentMouse.y - startMouse.y

        let newOrigin = CGPoint(
            x: startOrigin.x + deltaX,
            y: startOrigin.y + deltaY
        )

        window.setFrameOrigin(newOrigin)

        // Update HUD position to follow the button in real-time
        if FloatingMicTextHUD.shared.isVisible {
            FloatingMicTextHUD.shared.updatePosition(near: window.frame)
        }
    }

    func finishMoving() {
        dragStartOrigin = nil
        dragStartMouseLocation = nil
        debouncePositionSave()

        // Clear saved HUD position so next show() will position near the button
        // This ensures HUD appears near the button after it's been moved
        UserDefaults.standard.removeObject(forKey: FloatingMicConstants.hudPositionKey)
    }

    // MARK: - Recording Control

    func startRecording() {
        guard let appState = appState else {
            logger.error("startRecording: appState is nil")
            return
        }
        guard !appState.isRecording else {
            logger.debug("startRecording: already recording, skipping")
            return
        }

        // Use the last known frontmost app (tracked by observer)
        targetApp = lastFrontmostApp

        // Fallback: try current frontmost
        if targetApp == nil {
            let frontApp = NSWorkspace.shared.frontmostApplication
            if frontApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
                targetApp = frontApp
            }
        }

        // Always use HUD mode - direct insertion via Accessibility API is unreliable
        // across different apps (Word, Stickies, etc. don't expose text elements properly)
        isUsingDirectInsertion = false
        lastInsertedPartialText = ""

        logger.debug("Starting recording, targetApp=\(self.targetApp?.localizedName ?? "none", privacy: .public)")

        // Show the HUD for real-time transcription display
        if let buttonFrame = buttonWindow?.frame {
            logger.debug("Button window frame: \(buttonFrame.debugDescription, privacy: .public)")
            FloatingMicTextHUD.shared.show(near: buttonFrame)
        } else {
            logger.warning("Button window is nil or has no frame - HUD will not appear")
        }

        // Start STT without showing the panel
        startQuickSTT()
    }

    func stopRecording() {
        guard let appState = appState else { return }
        guard appState.isRecording else { return }

        logger.debug("Stopping recording, transcription length=\(appState.currentTranscription.count)")

        // Stop the STT service
        appState.realtimeSTTService?.stopListening()
        appState.realtimeSTTService = nil
        appState.isRecording = false

        appState.durationTimer?.invalidate()
        appState.durationTimer = nil
        appState.recordingStartTime = nil

        // Insert final text (HUD will be hidden after insertion completes)
        let finalText = appState.currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            // Update HUD to show "Pasting..." status
            NotificationCenter.default.post(
                name: FloatingMicConstants.transcriptionUpdatedNotification,
                object: finalText + "\n(Pasting...)"
            )
            insertFinalText(finalText)
        } else {
            // No text to insert, hide HUD immediately
            FloatingMicTextHUD.shared.hide()
        }

        // Reset state
        appState.transcriptionState = .idle
        appState.currentTranscription = ""
        lastInsertedPartialText = ""
        isUsingDirectInsertion = false
        // Note: targetApp is cleared after insertion completes
    }

    func toggleRecording() {
        guard let appState = appState else { return }
        if appState.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    // MARK: - Text Insertion

    /// Called when partial transcription is received (for streaming display/insertion)
    func handlePartialTranscription(_ text: String) {
        // Always use HUD mode - direct insertion is unreliable across apps
        // Update the HUD display
        NotificationCenter.default.post(
            name: FloatingMicConstants.transcriptionUpdatedNotification,
            object: text
        )
    }

    /// Called when final transcription is ready
    func handleFinalTranscription(_ text: String) {
        // Final text will be inserted via clipboard on stopRecording()
        // Update HUD with final text
        if !text.isEmpty {
            NotificationCenter.default.post(
                name: FloatingMicConstants.transcriptionUpdatedNotification,
                object: text
            )
        }
    }

    private func insertFinalText(_ text: String) {
        guard !text.isEmpty else { return }

        logger.debug("Inserting text via clipboard, length=\(text.count)")

        // Save clipboard state for restoration after paste
        let savedClipboardState = ClipboardService.shared.saveClipboardState()
        let targetAppToActivate = targetApp

        // Clear targetApp early to prevent stale reference
        targetApp = nil

        // Check if target app is still running
        if let targetApp = targetAppToActivate, targetApp.isTerminated {
            logger.warning("Target app '\(targetApp.localizedName ?? "unknown", privacy: .public)' has been terminated")
            // Keep text on clipboard so user doesn't lose it
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            FloatingMicTextHUD.shared.hide()
            showTargetAppClosedAlert(appName: targetApp.localizedName)
            return
        }

        // Use clipboard paste
        if let targetApp = targetAppToActivate {
            // Activate target app first
            let activated = targetApp.activate()

            logger.debug("Activating target app: \(targetApp.localizedName ?? "unknown", privacy: .public), success: \(activated)")

            if !activated {
                // Activation failed — app may have closed between check and activate
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                FloatingMicTextHUD.shared.hide()
                showTargetAppClosedAlert(appName: targetApp.localizedName)
                return
            }

            // Delay to allow app activation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task {
                    let pasted = await ClipboardService.shared.copyAndPaste(text)

                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                    await MainActor.run {
                        if pasted {
                            ClipboardService.shared.restoreClipboardState(savedClipboardState)
                            logger.debug("Text insertion completed, clipboard restored")
                        } else {
                            // Paste failed — keep text on clipboard for manual paste
                            logger.warning("Paste failed, text preserved on clipboard")
                            self.showPasteFailedAlert()
                        }
                        FloatingMicTextHUD.shared.hide()
                    }
                }
            }
        } else {
            logger.debug("No target app, pasting to current frontmost app")

            // No target app, just paste to current frontmost
            Task {
                let pasted = await ClipboardService.shared.copyAndPaste(text)

                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                await MainActor.run {
                    if pasted {
                        ClipboardService.shared.restoreClipboardState(savedClipboardState)
                        logger.debug("Text insertion completed, clipboard restored")
                    } else {
                        logger.warning("Paste failed, text preserved on clipboard")
                        self.showPasteFailedAlert()
                    }
                    FloatingMicTextHUD.shared.hide()
                }
            }
        }
    }

    private func showTargetAppClosedAlert(appName: String?) {
        let alert = NSAlert()
        let name = appName ?? NSLocalizedString("The target application", comment: "Fallback name for closed app")
        alert.messageText = NSLocalizedString("Target App Unavailable", comment: "Alert title when target app is closed")
        alert.informativeText = String(
            format: NSLocalizedString("'%@' is no longer running. The transcribed text has been saved to your clipboard. You can paste it manually with ⌘V.", comment: "Alert message when target app is closed"),
            name
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
        alert.runModal()
    }

    private func showPasteFailedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Paste Failed", comment: "Alert title when paste fails")
        alert.informativeText = NSLocalizedString("Could not paste the text automatically. The transcribed text has been saved to your clipboard. You can paste it manually with ⌘V.", comment: "Alert message when paste fails")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
        alert.runModal()
    }

    // MARK: - Quick STT (without panel)

    private func startQuickSTT() {
        guard let appState = appState else { return }

        // Close any open panels first
        if appState.showFloatingWindow {
            appState.showFloatingWindow = false
        }
        if appState.showTTSWindow {
            appState.stopTTS()
            appState.showTTSWindow = false
        }

        appState.currentTranscription = ""
        appState.errorMessage = nil
        appState.transcriptionState = .preparing

        Task {
            await appState.startRealtimeSTTForQuickMode(delegate: self)

            await MainActor.run {
                appState.isRecording = true
                appState.transcriptionState = .recording

                // Start duration timer
                appState.recordingDuration = 0
                appState.recordingStartTime = Date()
                appState.durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak appState] _ in
                    Task { @MainActor in
                        guard let appState = appState, let startTime = appState.recordingStartTime else { return }
                        appState.recordingDuration = Date().timeIntervalSince(startTime)
                    }
                }
            }
        }
    }

    // MARK: - Window Position

    private func debouncePositionSave() {
        positionSaveTimer?.invalidate()
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveWindowPosition()
            }
        }
    }

    private func saveWindowPosition() {
        guard let frame = buttonWindow?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: positionKey)
    }

    private func savedFrameOrDefault() -> NSRect {
        logger.debug("Trying to find focused element...")
        logger.debug("lastFrontmostApp = \(self.lastFrontmostApp?.localizedName ?? "nil", privacy: .public)")

        // Always try to position near the focused element of the frontmost app first
        if let focusedRect = getFocusedElementPosition() {
            logger.debug("Found focused element at \(focusedRect.debugDescription, privacy: .public)")
            let result = positionNearElement(focusedRect)
            logger.debug("Positioning button at \(result.debugDescription, privacy: .public)")
            return result
        }

        // Fallback to saved position if focused element not found
        if let frameString = UserDefaults.standard.string(forKey: positionKey) {
            let savedFrame = NSRectFromString(frameString)
            if savedFrame.width > 0 && savedFrame.height > 0 {
                // Validate saved position is on a connected screen
                let savedRect = NSRect(
                    x: savedFrame.origin.x,
                    y: savedFrame.origin.y,
                    width: buttonSize,
                    height: buttonSize
                )

                if let validatedRect = validatePositionOnConnectedScreens(savedRect) {
                    logger.debug("Using saved position as fallback: \(validatedRect.debugDescription, privacy: .public)")
                    return validatedRect
                } else {
                    logger.debug("Saved position is not on any connected screen, discarding")
                    // Clear invalid saved position
                    UserDefaults.standard.removeObject(forKey: positionKey)
                }
            }
        }

        logger.debug("Could not get focused element, using default position")

        // Default: bottom-right area of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            return NSRect(
                x: screenFrame.maxX - buttonSize - 80,
                y: screenFrame.minY + 80,
                width: buttonSize,
                height: buttonSize
            )
        }

        return NSRect(origin: CGPoint(x: 100, y: 100), size: NSSize(width: buttonSize, height: buttonSize))
    }

    /// Get the position of the focused UI element in the frontmost app using Accessibility API
    private func getFocusedElementPosition() -> NSRect? {
        // Use the last known frontmost app, or find one from window list
        let frontApp = lastFrontmostApp ?? findTopmostNonSpeechDockApp()
        guard let frontApp = frontApp else {
            logger.debug("No frontmost app found for positioning")
            return nil
        }

        logger.debug("Getting focused element from \(frontApp.localizedName ?? "unknown", privacy: .public)")

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success,
              let element = focusedElement,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        // Safe cast to AXUIElement
        let axElement = element as! AXUIElement  // Safe after CFGetTypeID check

        var position: AnyObject?
        var size: AnyObject?

        let posResult = AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &position)
        let sizeResult = AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &size)

        guard posResult == .success, sizeResult == .success else {
            logger.debug("Could not get position/size from focused element (pos=\(posResult.rawValue), size=\(sizeResult.rawValue))")
            return nil
        }

        // Verify AXValue types before casting
        guard let positionValue = position,
              let sizeValueObj = size,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValueObj) == AXValueGetTypeID() else {
            logger.debug("Position or size is not an AXValue")
            return nil
        }

        var point = CGPoint.zero
        var sizeValue = CGSize.zero

        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValueObj as! AXValue, .cgSize, &sizeValue) else {
            logger.debug("Could not extract CGPoint/CGSize from AXValue")
            return nil
        }

        logger.debug("Raw focused element position (AX coords): \(point.debugDescription, privacy: .public), size: \(sizeValue.debugDescription, privacy: .public)")

        // AXPosition is in screen coordinates with origin at top-left of primary screen
        // We need to find which screen contains this element and convert to NSWindow coordinates

        // Find the screen that contains this point (using AX coordinates)
        let axPoint = point
        var containingScreen: NSScreen?

        for screen in NSScreen.screens {
            // Convert screen frame to AX coordinates (top-left origin)
            let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? NSScreen.main?.frame.height ?? 0
            let axScreenOriginY = primaryHeight - screen.frame.maxY
            let axScreenFrame = NSRect(
                x: screen.frame.origin.x,
                y: axScreenOriginY,
                width: screen.frame.width,
                height: screen.frame.height
            )

            if axScreenFrame.contains(axPoint) {
                containingScreen = screen
                break
            }
        }

        // Use the containing screen, or fall back to main screen
        guard let screen = containingScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            logger.debug("No screen available for positioning")
            return nil
        }

        logger.debug("Element is on screen: \(screen.localizedName, privacy: .public)")

        // Convert from AX coordinates (top-left origin) to NS coordinates (bottom-left origin)
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? screen.frame.height
        let nsY = primaryHeight - point.y - sizeValue.height

        return NSRect(x: point.x, y: nsY, width: sizeValue.width, height: sizeValue.height)
    }

    /// Calculate button position near the focused element
    private func positionNearElement(_ elementRect: NSRect) -> NSRect {
        // Find which screen contains the element
        var containingScreen: NSScreen?
        for screen in NSScreen.screens {
            if screen.frame.intersects(elementRect) {
                containingScreen = screen
                break
            }
        }

        // Fall back to main screen if element not found on any screen
        guard let screen = containingScreen ?? NSScreen.main else {
            return NSRect(origin: CGPoint(x: 100, y: 100), size: NSSize(width: buttonSize, height: buttonSize))
        }

        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 16

        logger.debug("Positioning on screen: \(screen.localizedName, privacy: .public), frame: \(screenFrame.debugDescription, privacy: .public)")

        // Position to the right of the element, vertically centered
        var x = elementRect.maxX + margin
        var y = elementRect.midY - buttonSize / 2

        // If button would go off the right edge, position to the left of the element
        if x + buttonSize > screenFrame.maxX {
            x = elementRect.minX - buttonSize - margin
        }

        // If still off screen (element spans full width), position at right edge
        if x < screenFrame.minX {
            x = screenFrame.maxX - buttonSize - margin
        }

        // Clamp Y to screen bounds
        y = max(screenFrame.minY + margin, min(y, screenFrame.maxY - buttonSize - margin))

        return NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
    }

    /// Validates that a position is on a connected screen
    /// If the position is partially off-screen, it's adjusted to fit
    /// Returns nil if the position is completely off all screens
    private func validatePositionOnConnectedScreens(_ rect: NSRect) -> NSRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // Check if the rect intersects with any connected screen
        for screen in screens {
            let screenFrame = screen.visibleFrame
            if screenFrame.intersects(rect) {
                // Adjust to keep within this screen's bounds
                var adjusted = rect
                let margin = FloatingMicConstants.positionMargin

                if adjusted.maxX > screenFrame.maxX {
                    adjusted.origin.x = screenFrame.maxX - adjusted.width - margin
                }
                if adjusted.minX < screenFrame.minX {
                    adjusted.origin.x = screenFrame.minX + margin
                }
                if adjusted.maxY > screenFrame.maxY {
                    adjusted.origin.y = screenFrame.maxY - adjusted.height - margin
                }
                if adjusted.minY < screenFrame.minY {
                    adjusted.origin.y = screenFrame.minY + margin
                }

                return adjusted
            }
        }

        // Position is not on any connected screen
        return nil
    }

    // MARK: - App Activation Tracking

    /// Find the topmost app that is not SpeechDock using the window list
    private func findTopmostNonSpeechDockApp() -> NSRunningApplication? {
        let myBundleId = Bundle.main.bundleIdentifier

        // Get the window list ordered front to back
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            // Skip windows without an owner
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 else {
                continue
            }

            // Skip menu bar and other system windows (layer != 0)
            if let layer = windowInfo[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }

            // Get the owning application
            guard let app = NSRunningApplication(processIdentifier: ownerPID) else {
                continue
            }

            // Skip SpeechDock
            if app.bundleIdentifier == myBundleId {
                continue
            }

            // Skip apps without a bundle identifier (system processes)
            guard app.bundleIdentifier != nil else {
                continue
            }

            logger.debug("Found topmost app from window list: \(app.localizedName ?? "unknown", privacy: .public)")

            return app
        }

        return nil
    }

    private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        // Ignore our own app
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastFrontmostApp = app
            logger.debug("Tracked frontmost app: \(app.localizedName ?? "unknown", privacy: .public)")
        }
    }
}

// MARK: - RealtimeSTTDelegate

extension FloatingMicButtonManager: RealtimeSTTDelegate {
    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didReceivePartialResult text: String) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.currentTranscription = text
            handlePartialTranscription(text)
            logger.debug("Partial result received, length=\(text.count)")
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didReceiveFinalResult text: String) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.currentTranscription = text
            handleFinalTranscription(text)
            logger.debug("Final result received, length=\(text.count)")
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didFailWithError error: Error) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.errorMessage = error.localizedDescription
            appState.transcriptionState = .error(error.localizedDescription)
            logger.error("Error: \(error.localizedDescription, privacy: .public)")
            stopRecording()
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didChangeListeningState isListening: Bool) {
        Task { @MainActor in
            guard let appState = appState else { return }
            logger.debug("Listening state changed: \(isListening)")
            if !isListening && appState.isRecording {
                // VAD or service stopped - finalize
                stopRecording()
            }
        }
    }
}
