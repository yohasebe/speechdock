import SwiftUI

/// Permission setup view displayed as a checklist with real-time status updates.
/// Every permission is optional until its associated feature is used.
@Observable
final class PermissionSetupReason { var message: String? }
struct PermissionSetupView: View {
    var permissionService = PermissionService.shared
    var reason = PermissionSetupReason()
    var onContinue: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)

                Text("SpeechDock Permissions")
                    .font(.title2.bold())

                Text(reason.message ?? NSLocalizedString("Allow only the features you need. Text to speech works without microphone access.", comment: "Permission setup introduction"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)
            .padding(.horizontal, 24)

            Divider()
                .padding(.horizontal, 24)

            // Permission rows
            VStack(spacing: 0) {
                permissionRow(
                    icon: "mic.fill",
                    name: NSLocalizedString("Microphone", comment: "Permission name"),
                    description: NSLocalizedString("For speech recognition", comment: "Microphone permission description"),
                    badge: .optional,
                    status: permissionService.microphoneStatus,
                    action: {
                        if permissionService.microphoneStatus == .notRequested {
                            Task { await permissionService.requestMicrophone() }
                        } else { permissionService.openMicrophoneSettings() }
                    }
                )

                Divider()
                    .padding(.horizontal, 32)

                permissionRow(
                    icon: "hand.raised.fill",
                    name: NSLocalizedString("Accessibility", comment: "Permission name"),
                    description: NSLocalizedString("For inserting text into other apps", comment: "Accessibility permission description"),
                    badge: .recommended,
                    status: permissionService.accessibilityGranted ? .granted : .notGranted,
                    action: { permissionService.openAccessibilitySettings() }
                )

                Divider()
                    .padding(.horizontal, 32)

                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    name: NSLocalizedString("Screen Recording", comment: "Permission name"),
                    description: NSLocalizedString("For OCR, system/app audio capture and window thumbnails", comment: "Screen recording permission description"),
                    badge: .optional,
                    status: permissionService.screenRecordingGranted ? .granted : .notGranted,
                    action: { permissionService.openScreenRecordingSettings() }
                )
            }
            .padding(.vertical, 12)

            Text("If Screen Recording is enabled in System Settings but still unavailable here, restart SpeechDock.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)

            Spacer()

            Divider()
                .padding(.horizontal, 24)

            // Footer buttons
            HStack(spacing: 12) {
                Button(action: onLater) {
                    Text("Later")
                        .frame(width: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onContinue) {
                    Text("Continue")
                        .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.vertical, 16)
        }
        .frame(width: 540, height: 530)
        .animation(.snappy, value: permissionService.microphoneGranted)
        .animation(.snappy, value: permissionService.accessibilityGranted)
        .animation(.snappy, value: permissionService.screenRecordingGranted)
    }

    // MARK: - Permission Row

    private enum PermissionBadge {
        case recommended, optional

        var text: String {
            switch self {
            case .recommended: return NSLocalizedString("Recommended", comment: "Permission badge")
            case .optional: return NSLocalizedString("Optional", comment: "Permission badge")
            }
        }

        var color: Color {
            switch self {
            case .recommended: return .orange
            case .optional: return .secondary
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        name: String,
        description: String,
        badge: PermissionBadge,
        status: PermissionAccessStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(status == .granted ? .green : .accentColor)
                .frame(width: 28)

            // Name and description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))

                    Text(badge.text)
                        .font(.callout.weight(.medium))
                        .labelBadge(foreground: badge.color, background: badge.color.opacity(0.15))
                }

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status indicator
            if status == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(status.label).font(.callout).foregroundStyle(.secondary)
                    Button(action: action) {
                        Text(status == .notRequested ? "Allow" : "Open Settings")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
