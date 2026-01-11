import AppKit
import AVFoundation

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

        // Request microphone permission
        requestMicrophonePermission()
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

    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    DispatchQueue.main.async {
                        self.showMicrophonePermissionAlert()
                    }
                }
            }
        case .denied, .restricted:
            showMicrophonePermissionAlert()
        case .authorized:
            break
        @unknown default:
            break
        }
    }

    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "TypeTalk needs microphone access to record audio for transcription. Please enable it in System Settings > Privacy & Security > Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
