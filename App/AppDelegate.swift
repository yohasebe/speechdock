import AppKit
import AVFoundation
import ApplicationServices

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

        // Initialize and register hotkey service immediately
        hotKeyService = HotKeyService()

        // Setup hotkey with AppState on main actor
        Task { @MainActor in
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

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyService?.unregisterAllHotKeys()
    }

    /// Check all required permissions at startup
    private func checkRequiredPermissions() {
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibilityGranted = AXIsProcessTrusted()

        print("Permission check: Microphone=\(microphoneStatus.rawValue), Accessibility=\(accessibilityGranted)")

        // If both permissions are missing, show combined alert
        if (microphoneStatus == .denied || microphoneStatus == .restricted || microphoneStatus == .notDetermined) && !accessibilityGranted {
            print("Permission check: Both permissions missing, showing combined alert")
            showCombinedPermissionAlert(microphoneStatus: microphoneStatus)
        } else {
            // Check individually
            if microphoneStatus == .notDetermined {
                print("Permission check: Requesting microphone access")
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if !granted {
                        DispatchQueue.main.async {
                            self.showMicrophonePermissionAlert()
                        }
                    }
                }
            } else if microphoneStatus == .denied || microphoneStatus == .restricted {
                print("Permission check: Microphone denied/restricted, showing alert")
                showMicrophonePermissionAlert()
            } else {
                print("Permission check: Microphone already authorized")
            }

            if !accessibilityGranted {
                print("Permission check: Accessibility not granted, showing alert")
                showAccessibilityPermissionAlert()
            } else {
                print("Permission check: Accessibility already granted")
            }
        }
    }

    /// Show combined permission alert when both are needed
    private func showCombinedPermissionAlert(microphoneStatus: AVAuthorizationStatus) {
        // Activate app to ensure alert is visible (needed for accessory apps)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = """
        TypeTalk needs the following permissions to work properly:

        • Microphone: For speech recognition
        • Accessibility: For global keyboard shortcuts and text insertion

        Please grant these permissions in System Settings > Privacy & Security.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open Accessibility settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            // Also request microphone permission if not determined
            if microphoneStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            }
        } else if response == .alertSecondButtonReturn {
            // Open Microphone settings
            if microphoneStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func showMicrophonePermissionAlert() {
        // Activate app to ensure alert is visible (needed for accessory apps)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "TypeTalk needs microphone access to record audio for transcription. Please enable it in System Settings > Privacy & Security > Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showAccessibilityPermissionAlert() {
        // Activate app to ensure alert is visible (needed for accessory apps)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "TypeTalk needs Accessibility access to use global keyboard shortcuts and insert transcribed text. Please enable it in System Settings > Privacy & Security > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
