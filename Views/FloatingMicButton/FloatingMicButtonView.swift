import SwiftUI

/// A floating microphone button for quick STT access
struct FloatingMicButtonView: View {
    @Bindable var appState: AppState
    let manager: FloatingMicButtonManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("quickMicMovementHintSeen") private var hintSeen = false
    @State private var showHint = false
    @State private var isHovering = false
    @State private var pulseAnimation = false
    @State private var isDragging = false

    private let buttonSize: CGFloat = FloatingMicConstants.buttonSize

    var body: some View {
        ZStack {
            // Main button circle with blur background
            Circle()
                .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                .frame(width: buttonSize, height: buttonSize)

            // Button content
            ZStack {
                // Background circle
                Circle()
                    .fill(buttonBackground)
                    .frame(width: buttonSize - 4, height: buttonSize - 4)

                // Border for visibility
                Circle()
                    .stroke(borderColor, lineWidth: borderWidth)
                    .frame(width: buttonSize - 4, height: buttonSize - 4)

                // Recording pulse animation
                if appState.isRecording && !reduceMotion {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 2)
                        .frame(width: buttonSize - 4, height: buttonSize - 4)
                        .scaleEffect(pulseAnimation ? 1.4 : 1.0)
                        .opacity(pulseAnimation ? 0 : 0.8)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: false),
                            value: pulseAnimation
                        )
                }

                // Microphone icon
                Image(systemName: micIconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(iconColor)
            }
        }
        .frame(width: buttonSize, height: buttonSize)
        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
        .contentShape(Circle())
        .onTapGesture {
            if !isDragging {
                manager.toggleRecording()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    if !isDragging {
                        isDragging = true
                        manager.startDragging()
                    }
                    manager.continueDragging()
                }
                .onEnded { _ in
                    manager.finishMoving()
                    // Reset drag state after a short delay to prevent tap from firing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isDragging = false
                    }
                }
        )
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onChange(of: appState.isRecording) { _, isRecording in
            if isRecording {
                pulseAnimation = !reduceMotion
            } else {
                pulseAnimation = false
            }
        }
        .contextMenu {
            contextMenuContent
        }
        .help(tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Quick Transcription"))
        .accessibilityValue(Text(appState.transcriptionState == .preparing ? "Preparing speech recognition..." : (appState.isRecording ? "Recording..." : "Stopped")))
        .accessibilityHint(Text("Click to dictate; drag to move"))
        .accessibilityAction { manager.toggleRecording() }
        .onChange(of: reduceMotion) { _, reduced in pulseAnimation = !reduced && appState.isRecording }
        .onAppear {
            if !hintSeen { showHint = true; hintSeen = true }
        }
        .popover(isPresented: $showHint) {
            VStack(spacing: 12) {
                Text("Click to dictate; drag to move")
                Button("OK") { showHint = false }
            }.padding()
        }
    }

    // MARK: - Computed Properties

    private var buttonBackground: some ShapeStyle {
        if appState.isRecording {
            return AnyShapeStyle(Color.red.opacity(0.9))
        } else if isHovering {
            return AnyShapeStyle(Color.accentColor.opacity(0.8))
        } else {
            return AnyShapeStyle(Color.secondary.opacity(0.45))
        }
    }

    private var borderColor: Color {
        if appState.isRecording {
            return .red
        } else if isHovering {
            return .accentColor
        } else {
            return .primary.opacity(0.4)
        }
    }

    private var borderWidth: CGFloat {
        if appState.isRecording || isHovering {
            return 1.5
        } else {
            return 1.2
        }
    }

    private var iconColor: Color {
        if appState.isRecording || isHovering {
            return .white
        } else {
            return .primary
        }
    }

    private var micIconName: String {
        if appState.isRecording {
            return "stop.fill"
        } else {
            return "mic.fill"
        }
    }

    private var shortcutString: String {
        appState.hotKeyService?.quickTranscriptionKeyCombo.displayString ?? "⌃⌥M"
    }

    private var tooltipText: String {
        if appState.isRecording {
            let duration = formatDuration(appState.recordingDuration)
            return String(format: NSLocalizedString("Recording %@ — click or %@ to stop", comment: "Quick mic help"), duration, shortcutString)
        } else {
            return String(format: NSLocalizedString("Click or %@ to dictate; drag to move", comment: "Quick mic help"), shortcutString)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        // Provider selection
        Menu("STT Provider") {
            ForEach(RealtimeSTTProvider.allCases, id: \.self) { provider in
                Button(action: {
                    appState.selectedRealtimeProvider = provider
                }) {
                    HStack {
                        Text(provider.rawValue)
                        if provider == appState.selectedRealtimeProvider {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(provider.requiresAPIKey && !hasAPIKey(for: provider))
            }
        }

        Divider()

        // Info about how it works
        Label("Shows HUD while recording", systemImage: "text.bubble")
        Label("Pastes text when done", systemImage: "doc.on.clipboard")

        Divider()

        Button("Hide Mic Button") {
            appState.showFloatingMicButton = false
            manager.hide()
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func hasAPIKey(for provider: RealtimeSTTProvider) -> Bool {
        guard let envKeyName = provider.envKeyName else { return true }
        return APIKeyManager.shared.hasAPIKey(for: envKeyName)
    }
}

#Preview {
    FloatingMicButtonView(
        appState: AppState.shared,
        manager: FloatingMicButtonManager.shared
    )
    .frame(width: 100, height: 100)
    .background(Color.gray.opacity(0.3))
}
