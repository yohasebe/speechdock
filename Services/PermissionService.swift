import AppKit
import AVFoundation
import ApplicationServices

/// Reactive permission monitoring service.
/// Monitors Microphone, Accessibility, and Screen Recording permissions
/// and updates state in real-time via polling and system notifications.
@Observable
@MainActor
final class PermissionService {
    static let shared = PermissionService()

    // MARK: - Permission State

    private(set) var microphoneGranted: Bool = false
    private(set) var accessibilityGranted: Bool = false
    private(set) var screenRecordingGranted: Bool = false

    /// All required permissions (Microphone) are granted
    var allRequiredGranted: Bool { microphoneGranted }

    /// All permissions are granted
    var allGranted: Bool { microphoneGranted && accessibilityGranted && screenRecordingGranted }

    /// Whether any permission is missing
    var hasAnyMissing: Bool { !allGranted }

    // MARK: - Monitoring State

    private var pollingTask: Task<Void, Never>?
    private var notificationObserver: NSObjectProtocol?
    private(set) var isMonitoring = false

    // MARK: - Init

    private init() {
        refreshAllPermissions()
    }

    // MARK: - Permission Checking

    /// Refresh all permission states immediately
    func refreshAllPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    // MARK: - Monitoring

    /// Start monitoring permission changes via polling and system notifications.
    /// Call when the permission setup window is shown.
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        refreshAllPermissions()
        startPolling()
        startAccessibilityNotificationListener()
        dprint("PermissionService: Started monitoring")

    }

    /// Stop monitoring permission changes.
    /// Call when the permission setup window is closed.
    func stopMonitoring() {
        isMonitoring = false

        pollingTask?.cancel()
        pollingTask = nil

        if let observer = notificationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            notificationObserver = nil
        }
        dprint("PermissionService: Stopped monitoring")

    }

    /// Polling loop with adaptive intervals.
    /// Fast polling (0.5s) for the first 10 seconds, then slower (2s).
    /// Stops when all permissions are granted or after 5 minutes.
    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            var elapsedSeconds: Double = 0
            let maxDuration: Double = 300 // 5 minutes

            while !Task.isCancelled {
                let interval: Double = elapsedSeconds < 10 ? 0.5 : 2.0
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

                guard !Task.isCancelled else { break }

                await self?.refreshAllPermissions()

                if await self?.allGranted == true {
                    dprint("PermissionService: All permissions granted, stopping polling")

                    break
                }

                elapsedSeconds += interval
                if elapsedSeconds >= maxDuration {
                    dprint("PermissionService: Polling timeout reached")

                    break
                }
            }
        }
    }

    /// Listen for Accessibility permission changes via DistributedNotificationCenter.
    /// This provides faster detection than polling for accessibility changes.
    private func startAccessibilityNotificationListener() {
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Delay slightly to allow TCC database to update
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                self?.refreshAllPermissions()
            }
        }
    }

    // MARK: - Permission Requests

    /// Request microphone permission via system dialog.
    /// Returns true if permission was granted.
    @discardableResult
    func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneGranted = granted
            return granted
        }
        return status == .authorized
    }

    // MARK: - Open System Settings

    func openMicrophoneSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func openSystemSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
