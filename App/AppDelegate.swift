import AppKit
import AVFoundation
import ApplicationServices
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKeyService: HotKeyService?
    /// Flag to allow termination during permission checks (for macOS "Quit and Reopen")
    private var isCheckingPermissions = false

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
            // Setup status bar manager (must be done here, not in SpeechDockApp.init)
            StatusBarManager.shared.setup(appState: AppState.shared)

            AppState.shared.setupHotKey(self.hotKeyService!)

            // Mark app as initialized - AppleScript commands can now execute
            AppState.shared.isInitialized = true
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
        alert.messageText = "SpeechDock is already running"
        alert.informativeText = "Another instance of SpeechDock is already running. Please use the existing instance from the menu bar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Handle termination request - for menubar apps, ⌘Q should close panels, not quit
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Allow termination during permission checks (macOS "Quit and Reopen" from System Settings)
        if isCheckingPermissions {
            return .terminateNow
        }

        // NSApplicationDelegate methods are called on the main thread
        // Use assumeIsolated to safely access @MainActor state synchronously
        return MainActor.assumeIsolated {
            let appState = AppState.shared

            // Check if any panels are visible
            let panelVisible = appState.floatingWindowManager.isVisible
            let subtitleVisible = SubtitleOverlayManager.shared.isVisible

            // If any panel is visible, close it instead of terminating
            if panelVisible || subtitleVisible {
                // Clean up any active recordings
                appState.cancelRecording()

                // Stop TTS if active
                if appState.ttsState == .speaking || appState.ttsState == .loading {
                    appState.stopTTS()
                }

                // Close floating panel
                appState.floatingWindowManager.hideFloatingWindow()

                // Hide subtitle overlay
                SubtitleOverlayManager.shared.hide()

                // Cancel termination - panels closed, app stays running
                return .terminateCancel
            }

            // No panels visible - allow termination
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
        isCheckingPermissions = true
        defer { isCheckingPermissions = false }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibilityGranted = AXIsProcessTrusted()
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()

        #if DEBUG
        print("Permission check: Microphone=\(microphoneStatus.rawValue), Accessibility=\(accessibilityGranted), ScreenRecording=\(screenRecordingGranted)")
        #endif

        // Handle first-time microphone prompt (system dialog)
        if microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            // Don't show our dialog yet - let the system prompt finish first.
            // Remaining permissions will be checked on next launch.
            return
        }

        // Collect missing permissions
        var neededPermissions: [(name: String, description: String, url: String)] = []

        if microphoneStatus != .authorized {
            neededPermissions.append((
                name: "Microphone",
                description: "For speech recognition",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ))
        }
        if !accessibilityGranted {
            neededPermissions.append((
                name: "Accessibility",
                description: "For global keyboard shortcuts and text insertion",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ))
        }
        if !screenRecordingGranted {
            neededPermissions.append((
                name: "Screen Recording",
                description: "For window thumbnails in target selection",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ))
        }

        guard !neededPermissions.isEmpty else { return }

        showPermissionAlert(neededPermissions: neededPermissions)
    }

    /// Show a single permission alert listing all missing permissions.
    /// "Open Settings & Quit" opens System Settings and quits the app so macOS
    /// won't show its own "Quit and Reopen" dialog when the user toggles permissions.
    private func showPermissionAlert(neededPermissions: [(name: String, description: String, url: String)]) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Permissions Required"

        // Use accessory view for rich text with bold permission names
        let normalFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let textColor = NSColor.labelColor

        let body = NSMutableAttributedString()
        let normalAttrs: [NSAttributedString.Key: Any] = [.font: normalFont, .foregroundColor: textColor]
        let boldAttrs: [NSAttributedString.Key: Any] = [.font: boldFont, .foregroundColor: textColor]

        body.append(NSAttributedString(string: "SpeechDock needs the following permissions to work properly:\n\n", attributes: normalAttrs))

        for perm in neededPermissions {
            body.append(NSAttributedString(string: "• ", attributes: normalAttrs))
            body.append(NSAttributedString(string: perm.name, attributes: boldAttrs))
            body.append(NSAttributedString(string: ": \(perm.description)\n", attributes: normalAttrs))
        }

        body.append(NSAttributedString(string: "\nClick \"Open Settings & Quit\" to open System Settings. SpeechDock will quit so you can grant permissions without interruption. After granting them, relaunch SpeechDock.", attributes: normalAttrs))

        let textField = NSTextField(wrappingLabelWithString: "")
        textField.attributedStringValue = body
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.translatesAutoresizingMaskIntoConstraints = false

        // Container view with fixed width to prevent alert from stretching
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 0))
        container.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textField.topAnchor.constraint(equalTo: container.topAnchor),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            textField.widthAnchor.constraint(equalToConstant: 340)
        ])
        container.layoutSubtreeIfNeeded()
        container.frame.size.height = textField.fittingSize.height

        alert.accessoryView = container
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings & Quit")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open the first missing permission's settings page
            if let url = URL(string: neededPermissions[0].url) {
                NSWorkspace.shared.open(url)
            }
            // Small delay to ensure System Settings opens before we quit
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            NSApp.terminate(nil)
        } else {
            // Hide from Dock
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
