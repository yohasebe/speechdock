import AppKit
import AVFoundation
import ApplicationServices
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKeyService: HotKeyService?
    /// Flag set by explicit "Quit SpeechDock" menu action to bypass panel-close-first behavior
    var isExplicitQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check for duplicate instances
        if isAnotherInstanceRunning() {
            showDuplicateInstanceAlert()
            NSApp.terminate(nil)
            return
        }

        // Set as accessory app (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Clean up stale temporary files from previous sessions
        cleanupStaleTempFiles()

        // Clean up expired TTS voice caches
        Task { @MainActor in
            TTSVoiceCache.shared.cleanupExpiredCaches()
        }

        // Initialize and register hotkey service immediately
        hotKeyService = HotKeyService()

        // Setup status bar and hotkey with AppState on main actor
        Task { @MainActor in
            // Setup status bar manager (must be done here, not in SpeechDockApp.init)
            StatusBarManager.shared.setup(appState: AppState.shared)

            AppState.shared.setupHotKey(self.hotKeyService!)

            // Mark app as initialized - AppleScript commands can now execute
            AppState.shared.isInitialized = true

            // Donation reminder - disabled for now, enable when app gains traction
            // Task { @MainActor in
            //     try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            //     if AppState.shared.shouldShowDonationReminder() {
            //         AppState.shared.showDonationReminder()
            //     }
            // }
        }

        // Check permissions on first launch
        checkRequiredPermissions()
    }

    /// Check if another instance of SpeechDock is already running
    private func isAnotherInstanceRunning() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "SpeechDock"

        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if app.bundleIdentifier == bundleIdentifier && app.processIdentifier != currentPID {
                return true
            }
        }

        // Also check by process name for command-line execution
        let processName = ProcessInfo.processInfo.processName
        for app in runningApps {
            if app.localizedName == processName && app.processIdentifier != currentPID {
                return true
            }
        }

        return false
    }

    /// Show alert when duplicate instance is detected
    private func showDuplicateInstanceAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("SpeechDock is already running", comment: "Duplicate instance alert title")
        alert.informativeText = NSLocalizedString("Another instance of SpeechDock is already running. Please use the existing instance from the menu bar.", comment: "Duplicate instance alert message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
        alert.runModal()
    }

    /// Handle termination request - for menubar apps, ⌘Q should close panels, not quit
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Detect ⌘Q keyboard shortcut — close panels instead of quitting (menu bar app behavior)
        if !isExplicitQuit,
           let event = NSApp.currentEvent,
           event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "q" {
            return MainActor.assumeIsolated {
                let appState = AppState.shared

                // Clean up any active recordings
                appState.cancelRecording()

                // Stop TTS if active
                if appState.ttsState == .speaking || appState.ttsState == .loading {
                    appState.stopTTS()
                }

                // Close all visible panels/windows
                appState.floatingWindowManager.hideFloatingWindow()
                SubtitleOverlayManager.shared.hide()
                WindowManager.shared.closeSettingsWindow()
                PermissionSetupController.shared.dismiss()
                StatusBarManager.shared.closePanel()

                return .terminateCancel
            }
        }

        // Explicit quit (Quit button or app menu) — allow termination with cleanup
        return MainActor.assumeIsolated {
            let appState = AppState.shared
            appState.cancelRecording()
            if appState.ttsState == .speaking || appState.ttsState == .loading {
                appState.stopTTS()
            }
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyService?.unregisterAllHotKeys()

        // Clean up all SpeechDock temp files on termination
        cleanupAllTempFiles()
    }

    /// Prevent app from terminating when last window is closed (menu bar app)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Clean up all SpeechDock temporary files (called on app termination)
    private func cleanupAllTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for fileURL in contents {
                let filename = fileURL.lastPathComponent

                // Only clean up SpeechDock temp files (tts_* and stt_*)
                if filename.hasPrefix("tts_") || filename.hasPrefix("stt_") {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            // Ignore errors during termination cleanup
        }
    }

    /// Clean up stale temporary files from previous sessions
    /// Removes tts_* and stt_* files older than 1 hour from the temp directory
    private func cleanupStaleTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileManager = FileManager.default
        let oneHourAgo = Date().addingTimeInterval(-3600)

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )

            for fileURL in contents {
                let filename = fileURL.lastPathComponent

                // Only clean up SpeechDock temp files (tts_* and stt_*)
                guard filename.hasPrefix("tts_") || filename.hasPrefix("stt_") else {
                    continue
                }

                // Check file age
                if let attrs = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                   let creationDate = attrs.creationDate,
                   creationDate < oneHourAgo {
                    try? fileManager.removeItem(at: fileURL)
                    dprint("Cleaned up stale temp file: \(filename)")

                }
            }
        } catch {
            dprint("Failed to clean up temp files: \(error)")

        }
    }

    /// Check permissions at startup and show setup window if any are missing.
    /// Uses PermissionService for reactive monitoring — no app restart needed.
    private func checkRequiredPermissions() {
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        // Handle first-time microphone prompt (system dialog)
        if microphoneStatus == .notDetermined {
            Task { @MainActor in
                let permissionService = PermissionService.shared
                await permissionService.requestMicrophone()
                // After system dialog, check remaining permissions
                permissionService.refreshAllPermissions()
                if permissionService.hasAnyMissing {
                    PermissionSetupController.shared.show()
                }
            }
            return
        }

        // Show setup window if any permissions are missing
        Task { @MainActor in
            let permissionService = PermissionService.shared
            dprint("Permission check: Microphone=\(microphoneStatus.rawValue), Accessibility=\(permissionService.accessibilityGranted), ScreenRecording=\(permissionService.screenRecordingGranted)")

            if permissionService.hasAnyMissing {
                PermissionSetupController.shared.show()
            }
        }
    }
}
