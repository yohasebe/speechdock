import SwiftUI

/// Permission setup view displayed as a checklist with real-time status updates.
/// Shows Microphone (required), Accessibility (recommended), and Screen Recording (optional).
struct PermissionSetupView: View {
    let permissionService = PermissionService.shared
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

                Text("SpeechDock needs the following permissions to work properly.")
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
                    badge: .required,
                    isGranted: permissionService.microphoneGranted,
                    action: { permissionService.openMicrophoneSettings() }
                )

                Divider()
                    .padding(.horizontal, 32)

                permissionRow(
                    icon: "hand.raised.fill",
                    name: NSLocalizedString("Accessibility", comment: "Permission name"),
                    description: NSLocalizedString("For global keyboard shortcuts and text insertion", comment: "Accessibility permission description"),
                    badge: .recommended,
                    isGranted: permissionService.accessibilityGranted,
                    action: { permissionService.openAccessibilitySettings() }
                )

                Divider()
                    .padding(.horizontal, 32)

                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    name: NSLocalizedString("Screen Recording", comment: "Permission name"),
                    description: NSLocalizedString("For system/app audio capture and window thumbnails", comment: "Screen recording permission description"),
                    badge: .optional,
                    isGranted: permissionService.screenRecordingGranted,
                    action: { permissionService.openScreenRecordingSettings() }
                )
            }
            .padding(.vertical, 12)

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
                .disabled(!permissionService.microphoneGranted)
            }
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 420)
        .animation(.snappy, value: permissionService.microphoneGranted)
        .animation(.snappy, value: permissionService.accessibilityGranted)
        .animation(.snappy, value: permissionService.screenRecordingGranted)
    }

    // MARK: - Permission Row

    private enum PermissionBadge {
        case required, recommended, optional

        var text: String {
            switch self {
            case .required: return NSLocalizedString("Required", comment: "Permission badge")
            case .recommended: return NSLocalizedString("Recommended", comment: "Permission badge")
            case .optional: return NSLocalizedString("Optional", comment: "Permission badge")
            }
        }

        var color: Color {
            switch self {
            case .required: return .red
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
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(isGranted ? .green : .accentColor)
                .frame(width: 28)

            // Name and description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))

                    Text(badge.text)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badge.color.opacity(0.15))
                        .foregroundStyle(badge.color)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status indicator
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else {
                Button(action: action) {
                    Text("Open Settings")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
