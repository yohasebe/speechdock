import AppKit
import AVFoundation
import ApplicationServices
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKeyService: HotKeyService?

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

        // Initialize and register hotkey service immediately
        hotKeyService = HotKeyService()

        // Setup status bar and hotkey with AppState on main actor
        Task { @MainActor in
            // Setup status bar manager (must be done here, not in TypeTalkApp.init)
            StatusBarManager.shared.setup(appState: AppState.shared)

            AppState.shared.setupHotKey(self.hotKeyService!)
        }

        // Check permissions on first launch
        checkRequiredPermissions()
    }

    /// Check if another instance of TypeTalk is already running
    private func isAnotherInstanceRunning() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "TypeTalk"

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
        alert.messageText = "TypeTalk is already running"
        alert.informativeText = "Another instance of TypeTalk is already running. Please use the existing instance from the menu bar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Intercept ⌘Q when STT/TTS panels are visible - close panel instead of quitting
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // NSApplicationDelegate methods are called on the main thread
        // Use assumeIsolated to safely access @MainActor state synchronously
        return MainActor.assumeIsolated {
            let appState = AppState.shared

            // Check if any floating panel is visible
            if appState.floatingWindowManager.isVisible {
                // Cancel recording if active and close the panel (synchronously)
                appState.cancelRecording()
                return .terminateCancel
            }

            // Check if TTS is speaking
            if appState.ttsState == .speaking || appState.ttsState == .loading {
                // Stop TTS and close any TTS panel (synchronously)
                appState.stopTTS()
                appState.floatingWindowManager.hideFloatingWindow()
                return .terminateCancel
            }

            // No panels visible, allow termination
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyService?.unregisterAllHotKeys()

        // Clean up all TypeTalk temp files on termination
        cleanupAllTempFiles()
    }

    /// Prevent app from terminating when last window is closed (menu bar app)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Clean up all TypeTalk temporary files (called on app termination)
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

                // Only clean up TypeTalk temp files (tts_* and stt_*)
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

                // Only clean up TypeTalk temp files (tts_* and stt_*)
                guard filename.hasPrefix("tts_") || filename.hasPrefix("stt_") else {
                    continue
                }

                // Check file age
                if let attrs = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                   let creationDate = attrs.creationDate,
                   creationDate < oneHourAgo {
                    try? fileManager.removeItem(at: fileURL)
                    #if DEBUG
                    print("Cleaned up stale temp file: \(filename)")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            print("Failed to clean up temp files: \(error)")
            #endif
        }
    }

    /// Check all required permissions at startup
    private func checkRequiredPermissions() {
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibilityGranted = AXIsProcessTrusted()
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()

        #if DEBUG
        print("Permission check: Microphone=\(microphoneStatus.rawValue), Accessibility=\(accessibilityGranted), ScreenRecording=\(screenRecordingGranted)")
        #endif

        // Count how many permissions are missing
        let microphoneMissing = microphoneStatus != .authorized
        let accessibilityMissing = !accessibilityGranted
        let screenRecordingMissing = !screenRecordingGranted

        let missingCount = [microphoneMissing, accessibilityMissing, screenRecordingMissing].filter { $0 }.count

        // If multiple permissions are missing, show combined alert
        if missingCount >= 2 {
            #if DEBUG
            print("Permission check: Multiple permissions missing, showing combined alert")
            #endif
            showCombinedPermissionAlert(microphoneStatus: microphoneStatus)
        } else {
            // Check individually
            if microphoneStatus == .notDetermined {
                #if DEBUG
                print("Permission check: Requesting microphone access")
                #endif
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if !granted {
                        DispatchQueue.main.async {
                            self.showMicrophonePermissionAlert()
                        }
                    }
                }
            } else if microphoneStatus == .denied || microphoneStatus == .restricted {
                #if DEBUG
                print("Permission check: Microphone denied/restricted, showing alert")
                #endif
                showMicrophonePermissionAlert()
            } else {
                #if DEBUG
                print("Permission check: Microphone already authorized")
                #endif
            }

            if !accessibilityGranted {
                #if DEBUG
                print("Permission check: Accessibility not granted, showing alert")
                #endif
                showAccessibilityPermissionAlert()
            } else {
                #if DEBUG
                print("Permission check: Accessibility already granted")
                #endif
            }

            if !screenRecordingGranted {
                #if DEBUG
                print("Permission check: Screen Recording not granted, showing alert")
                #endif
                showScreenRecordingPermissionAlert()
            } else {
                #if DEBUG
                print("Permission check: Screen Recording already granted")
                #endif
            }
        }
    }

    /// Show combined permission alert when multiple permissions are needed
    private func showCombinedPermissionAlert(microphoneStatus: AVAuthorizationStatus) {
        // Show in Dock while permission dialog is open
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        var currentMicStatus = microphoneStatus

        // Keep showing dialog until user clicks "Later" or all permissions are granted
        while true {
            // Check current permission status
            let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let accessibilityGranted = AXIsProcessTrusted()
            let screenRecordingGranted = CGPreflightScreenCaptureAccess()

            // If all permissions are now granted, exit
            if micGranted && accessibilityGranted && screenRecordingGranted {
                break
            }

            // Re-activate app to bring alert to front (important after returning from System Settings)
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Permissions Required"

            // Build dynamic message based on what's still needed
            var neededPermissions: [String] = []
            if !micGranted {
                neededPermissions.append("• Microphone: For speech recognition")
            }
            if !accessibilityGranted {
                neededPermissions.append("• Accessibility: For global keyboard shortcuts and text insertion")
            }
            if !screenRecordingGranted {
                neededPermissions.append("• Screen Recording: For window thumbnails in target selection")
            }

            alert.informativeText = """
            TypeTalk needs the following permissions to work properly:

            \(neededPermissions.joined(separator: "\n"))

            Click a button below to open the relevant settings, grant the permission, then return here.
            """
            alert.alertStyle = .warning

            // Add buttons based on what's still needed (max 3 permission buttons + Later)
            var buttonActions: [() -> Void] = []

            if !accessibilityGranted {
                alert.addButton(withTitle: "Open Accessibility Settings")
                buttonActions.append {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if !screenRecordingGranted {
                alert.addButton(withTitle: "Open Screen Recording Settings")
                buttonActions.append {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if !micGranted {
                alert.addButton(withTitle: "Open Microphone Settings")
                buttonActions.append {
                    if currentMicStatus == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        currentMicStatus = .denied
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            let laterButtonIndex = buttonActions.count  // 0-indexed relative to first button

            if response.rawValue == 1000 + laterButtonIndex {
                // User clicked "Later"
                break
            } else {
                // Execute the corresponding action
                let buttonIndex = response.rawValue - 1000
                if buttonIndex >= 0 && buttonIndex < buttonActions.count {
                    buttonActions[buttonIndex]()
                }
            }

            // Wait for user to grant permission in System Settings
            // Give them time to interact with System Settings before showing the dialog again
            // Allow UI events to be processed while waiting (non-blocking)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.0))
        }

        // Hide from Dock after dialog is dismissed
        NSApp.setActivationPolicy(.accessory)
    }

    private func showMicrophonePermissionAlert() {
        // Show in Dock while permission dialog is open
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Keep showing dialog until user clicks "Later" or permission is granted
        while true {
            let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if micGranted {
                break
            }

            // Re-activate app to bring alert to front
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Microphone Access Required"
            alert.informativeText = "TypeTalk needs microphone access to record audio for transcription.\n\nPlease enable it in System Settings, then return here."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                // User clicked "Later"
                break
            } else if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }

            // Wait for user to grant permission
            // Allow UI events to be processed while waiting (non-blocking)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.0))
        }

        // Hide from Dock after dialog is dismissed
        NSApp.setActivationPolicy(.accessory)
    }

    private func showAccessibilityPermissionAlert() {
        // Show in Dock while permission dialog is open
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Keep showing dialog until user clicks "Later" or permission is granted
        while true {
            let accessibilityGranted = AXIsProcessTrusted()
            if accessibilityGranted {
                break
            }

            // Re-activate app to bring alert to front
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Accessibility Access Required"
            alert.informativeText = "TypeTalk needs Accessibility access to use global keyboard shortcuts and insert transcribed text.\n\nPlease enable it in System Settings, then return here."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                // User clicked "Later"
                break
            } else if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }

            // Wait for user to grant permission
            // Allow UI events to be processed while waiting (non-blocking)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.0))
        }

        // Hide from Dock after dialog is dismissed
        NSApp.setActivationPolicy(.accessory)
    }

    private func showScreenRecordingPermissionAlert() {
        // Show in Dock while permission dialog is open
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Keep showing dialog until user clicks "Later" or permission is granted
        while true {
            let screenRecordingGranted = CGPreflightScreenCaptureAccess()
            if screenRecordingGranted {
                break
            }

            // Re-activate app to bring alert to front
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Screen Recording Access Required"
            alert.informativeText = "TypeTalk needs Screen Recording access to show window thumbnails when selecting a paste target.\n\nPlease enable it in System Settings, then return here."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                // User clicked "Later"
                break
            } else if response == .alertFirstButtonReturn {
                // Try to trigger the system prompt first
                CGRequestScreenCaptureAccess()
                // Then open settings
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }

            // Wait for user to grant permission
            // Allow UI events to be processed while waiting (non-blocking)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.0))
        }

        // Hide from Dock after dialog is dismissed
        NSApp.setActivationPolicy(.accessory)
    }
}
