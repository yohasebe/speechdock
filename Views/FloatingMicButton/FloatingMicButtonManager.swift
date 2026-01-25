import AppKit
import SwiftUI

/// Manages the floating microphone button window for quick STT access
@MainActor
final class FloatingMicButtonManager {
    static let shared = FloatingMicButtonManager()

    private var buttonWindow: NSWindow?
    private weak var appState: AppState?
    private var positionSaveTimer: Timer?
    private var windowMoveObserver: Any?

    /// Partial text inserted via direct Accessibility API (for replacement on update)
    private(set) var lastInsertedPartialText: String = ""

    /// Whether we're using direct insertion mode for this session
    private(set) var isUsingDirectInsertion: Bool = false

    /// The app that was frontmost when recording started
    private var targetApp: NSRunningApplication?

    private let positionKey = "floatingMicButtonPosition"
    private let defaultSize = NSSize(width: 56, height: 56)

    private init() {}

    // MARK: - Show/Hide

    var isVisible: Bool {
        buttonWindow != nil
    }

    func show(appState: AppState) {
        guard buttonWindow == nil else { return }

        self.appState = appState

        let frame = savedFrameOrDefault()
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = WindowLevelCoordinator.shared.nextPanelLevel()
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        let contentView = FloatingMicButtonView(appState: appState, manager: self)
        window.contentView = NSHostingView(rootView: contentView)
        window.orderFrontRegardless()

        self.buttonWindow = window
        setupWindowMoveObserver(for: window)
    }

    func hide() {
        removeWindowMoveObserver()
        saveWindowPosition()

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

    // MARK: - Recording Control

    func startRecording() {
        guard let appState = appState else { return }
        guard !appState.isRecording else { return }

        // Capture the frontmost app before we potentially change focus
        targetApp = NSWorkspace.shared.frontmostApplication

        // Check insertion capability
        isUsingDirectInsertion = AccessibilityTextInsertionService.shared.canUseDirectInsertion()
        lastInsertedPartialText = ""

        #if DEBUG
        print("FloatingMic: Starting recording, directInsertion=\(isUsingDirectInsertion), targetApp=\(targetApp?.localizedName ?? "none")")
        #endif

        // Start STT without showing the panel
        startQuickSTT()
    }

    func stopRecording() {
        guard let appState = appState else { return }
        guard appState.isRecording else { return }

        #if DEBUG
        print("FloatingMic: Stopping recording")
        #endif

        // Stop the STT service
        appState.realtimeSTTService?.stopListening()
        appState.realtimeSTTService = nil
        appState.isRecording = false

        appState.durationTimer?.invalidate()
        appState.durationTimer = nil
        appState.recordingStartTime = nil

        // Insert final text if not already done via streaming
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

    /// Called when partial transcription is received (for streaming display/insertion)
    func handlePartialTranscription(_ text: String) {
        guard isUsingDirectInsertion else { return }

        // Replace previously inserted partial text with new partial
        if !lastInsertedPartialText.isEmpty {
            let success = AccessibilityTextInsertionService.shared.replacePartialText(
                oldText: lastInsertedPartialText,
                with: text
            )
            if success {
                lastInsertedPartialText = text
            }
        } else if !text.isEmpty {
            // First partial - insert directly
            let success = AccessibilityTextInsertionService.shared.insertTextDirectly(text)
            if success {
                lastInsertedPartialText = text
            }
        }
    }

    /// Called when final transcription is ready
    func handleFinalTranscription(_ text: String) {
        guard !text.isEmpty else { return }

        if isUsingDirectInsertion && !lastInsertedPartialText.isEmpty {
            // Replace the last partial with final
            _ = AccessibilityTextInsertionService.shared.replacePartialText(
                oldText: lastInsertedPartialText,
                with: text
            )
        }
        // Note: If not using direct insertion, text will be inserted on stopRecording()
    }

    private func insertFinalText(_ text: String) {
        guard !text.isEmpty else { return }

        // If we were doing direct insertion, text should already be there
        // If not, use clipboard paste
        if !isUsingDirectInsertion {
            // Activate target app first
            if let targetApp = targetApp {
                targetApp.activate()
                // Small delay for activation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Task {
                        await ClipboardService.shared.copyAndPaste(text)
                    }
                }
            } else {
                Task {
                    await ClipboardService.shared.copyAndPaste(text)
                }
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

    private func setupWindowMoveObserver(for window: NSWindow) {
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.debouncePositionSave()
            }
        }
    }

    private func removeWindowMoveObserver() {
        if let observer = windowMoveObserver {
            NotificationCenter.default.removeObserver(observer)
            windowMoveObserver = nil
        }
        positionSaveTimer?.invalidate()
        positionSaveTimer = nil
    }

    private func debouncePositionSave() {
        positionSaveTimer?.invalidate()
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
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
                return savedFrame
            }
        }

        // Default: bottom-right area of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            return NSRect(
                x: screenFrame.maxX - defaultSize.width - 80,
                y: screenFrame.minY + 80,
                width: defaultSize.width,
                height: defaultSize.height
            )
        }

        return NSRect(origin: CGPoint(x: 100, y: 100), size: defaultSize)
    }
}

// MARK: - RealtimeSTTDelegate

extension FloatingMicButtonManager: RealtimeSTTDelegate {
    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didReceivePartialResult text: String) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.currentTranscription = text
            handlePartialTranscription(text)
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didReceiveFinalResult text: String) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.currentTranscription = text
            handleFinalTranscription(text)
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didFailWithError error: Error) {
        Task { @MainActor in
            guard let appState = appState else { return }
            appState.errorMessage = error.localizedDescription
            appState.transcriptionState = .error(error.localizedDescription)
            stopRecording()
        }
    }

    nonisolated func realtimeSTT(_ service: RealtimeSTTService, didChangeListeningState isListening: Bool) {
        Task { @MainActor in
            guard let appState = appState else { return }
            if !isListening && appState.isRecording {
                // VAD or service stopped - finalize
                stopRecording()
            }
        }
    }
}
