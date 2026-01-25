import AppKit
import SwiftUI

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

    /// Starting window position for drag
    private var dragStartOrigin: CGPoint?

    private let positionKey = "floatingMicButtonPosition"
    private let buttonSize: CGFloat = 48

    private init() {}

    // MARK: - Show/Hide

    var isVisible: Bool {
        buttonWindow != nil
    }

    func show(appState: AppState) {
        guard buttonWindow == nil else { return }

        self.appState = appState

        let frame = savedFrameOrDefault()
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
    }

    func hide() {
        saveWindowPosition()
        positionSaveTimer?.invalidate()
        positionSaveTimer = nil

        buttonWindow?.orderOut(nil)
        buttonWindow = nil
        appState = nil

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

    func moveWindow(by translation: CGSize) {
        guard let window = buttonWindow else { return }

        if dragStartOrigin == nil {
            dragStartOrigin = window.frame.origin
        }

        guard let startOrigin = dragStartOrigin else { return }

        let newOrigin = CGPoint(
            x: startOrigin.x + translation.width,
            y: startOrigin.y - translation.height  // SwiftUI Y is inverted
        )
        window.setFrameOrigin(newOrigin)
    }

    func finishMoving() {
        dragStartOrigin = nil
        debouncePositionSave()
    }

    // MARK: - Recording Control

    func startRecording() {
        guard let appState = appState else { return }
        guard !appState.isRecording else { return }

        // Since our window doesn't take focus, the frontmost app should be the target
        targetApp = NSWorkspace.shared.frontmostApplication

        // If somehow we are frontmost, find the most recently active app
        if targetApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
            targetApp = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .first { $0.isActive }
        }

        // Check insertion capability before starting
        // Note: This checks the current focused element which may be in targetApp
        isUsingDirectInsertion = false  // Default to clipboard for reliability
        lastInsertedPartialText = ""

        #if DEBUG
        print("FloatingMic: Starting recording, targetApp=\(targetApp?.localizedName ?? "none")")
        #endif

        // Start STT without showing the panel
        startQuickSTT()
    }

    func stopRecording() {
        guard let appState = appState else { return }
        guard appState.isRecording else { return }

        #if DEBUG
        print("FloatingMic: Stopping recording, transcription=\(appState.currentTranscription)")
        #endif

        // Stop the STT service
        appState.realtimeSTTService?.stopListening()
        appState.realtimeSTTService = nil
        appState.isRecording = false

        appState.durationTimer?.invalidate()
        appState.durationTimer = nil
        appState.recordingStartTime = nil

        // Insert final text
        let finalText = appState.currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            insertFinalText(finalText)
        }

        // Reset state
        appState.transcriptionState = .idle
        appState.currentTranscription = ""
        targetApp = nil
        lastInsertedPartialText = ""
        isUsingDirectInsertion = false
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

    private func insertFinalText(_ text: String) {
        guard !text.isEmpty else { return }

        #if DEBUG
        print("FloatingMic: Inserting text: \(text)")
        #endif

        // Always use clipboard paste for reliability
        if let targetApp = targetApp {
            // Activate target app first
            targetApp.activate()

            // Delay to allow app activation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task {
                    await ClipboardService.shared.copyAndPaste(text)
                }
            }
        } else {
            // No target app, just paste
            Task {
                await ClipboardService.shared.copyAndPaste(text)
            }
        }
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
        if let frameString = UserDefaults.standard.string(forKey: positionKey) {
            let savedFrame = NSRectFromString(frameString)
            if savedFrame.width > 0 && savedFrame.height > 0 {
                return NSRect(
                    x: savedFrame.origin.x,
                    y: savedFrame.origin.y,
                    width: buttonSize,
                    height: buttonSize
                )
            }
        }

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
}

// MARK: - RealtimeSTTDelegate

extension FloatingMicButtonManager: RealtimeSTTDelegate {
    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didReceivePartialResult text: String) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.currentTranscription = text
            #if DEBUG
            print("FloatingMic: Partial result: \(text)")
            #endif
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didReceiveFinalResult text: String) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.currentTranscription = text
            #if DEBUG
            print("FloatingMic: Final result: \(text)")
            #endif
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didFailWithError error: Error) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.errorMessage = error.localizedDescription
            appState.transcriptionState = .error(error.localizedDescription)
            #if DEBUG
            print("FloatingMic: Error: \(error.localizedDescription)")
            #endif
            stopRecording()
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didChangeListeningState isListening: Bool) {
        Task { @MainActor in
            guard let appState = appState else { return }
            #if DEBUG
            print("FloatingMic: Listening state changed: \(isListening)")
            #endif
            if !isListening && appState.isRecording {
                // VAD or service stopped - finalize
                stopRecording()
            }
        }
    }
}
