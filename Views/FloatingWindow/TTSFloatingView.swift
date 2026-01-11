import SwiftUI

/// TTS state for the floating view
enum TTSState: Equatable {
    case idle
    case speaking
    case paused
    case loading
    case error(String)
}

struct TTSFloatingView: View {
    var appState: AppState
    let onClose: () -> Void

    @State private var editableText: String = ""
    @FocusState private var isTextEditorFocused: Bool

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.appState = appState
        self.onClose = onClose
        self._editableText = State(initialValue: appState.ttsText)
    }

    // Whether the text editor should be disabled
    private var isEditorDisabled: Bool {
        switch appState.ttsState {
        case .speaking, .loading, .paused:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                statusIcon
                Text(headerText)
                    .font(.headline)
                Spacer()

                // Provider badge
                Text(appState.selectedTTSProvider.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)

                Button(action: {
                    appState.stopTTS()
                    onClose()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Content area - always editable TextEditor
            contentArea

            // Action buttons
            actionButtons
        }
        .padding(16)
        .frame(width: 480)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .onAppear {
            editableText = appState.ttsText
            // Focus the text editor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextEditorFocused = true
            }
        }
        .onChange(of: appState.ttsText) { _, newValue in
            // Sync when appState.ttsText changes externally
            if editableText != newValue {
                editableText = newValue
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        Image(systemName: statusIconName)
            .foregroundColor(statusIconColor)
            .font(.title2)
            .frame(width: 28, height: 22)
    }

    private var statusIconName: String {
        switch appState.ttsState {
        case .idle: return "speaker.wave.2"
        case .speaking: return "speaker.wave.3.fill"
        case .loading: return "arrow.down.circle"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusIconColor: Color {
        switch appState.ttsState {
        case .idle: return .accentColor
        case .speaking: return .green
        case .loading: return .blue
        case .paused: return .orange
        case .error: return .red
        }
    }

    private var headerText: String {
        switch appState.ttsState {
        case .idle:
            return "Text-to-Speech"
        case .speaking:
            return "Speaking..."
        case .paused:
            return "Paused"
        case .loading:
            return "Generating audio..."
        case .error:
            return "Error"
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            // TextEditor - always visible, disabled during speaking/loading
            TextEditor(text: $editableText)
                .font(.body)
                .padding(8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)
                .frame(height: 120)
                .focused($isTextEditorFocused)
                .disabled(isEditorDisabled)
                .opacity(isEditorDisabled ? 0.7 : 1.0)

            // Overlay for speaking state - word highlighting
            if case .speaking = appState.ttsState, let range = appState.currentSpeakingRange {
                highlightOverlay(range: range)
            }

            // Loading overlay
            if case .loading = appState.ttsState {
                VStack(spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.blue.opacity(0.7))
                                .frame(width: 3, height: CGFloat.random(in: 6...18))
                        }
                    }
                    Text("Loading...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color(.windowBackgroundColor).opacity(0.9))
                .cornerRadius(8)
            }

            // Error overlay
            if case .error(let message) = appState.ttsState {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(8)
                .background(Color(.windowBackgroundColor).opacity(0.95))
                .cornerRadius(8)
            }
        }
    }

    @ViewBuilder
    private func highlightOverlay(range: NSRange) -> some View {
        // Create a transparent overlay that doesn't interfere with the text
        // The actual highlighting happens via the text display
        Color.clear
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Spacer()

            switch appState.ttsState {
            case .idle, .error:
                Button("Speak (⌘↩)") {
                    if !editableText.isEmpty {
                        appState.startTTSWithText(editableText)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(editableText.isEmpty)

                Button("Close (⌘W)") {
                    onClose()
                }
                .keyboardShortcut("w", modifiers: .command)

            case .speaking:
                Button("Pause (⌘P)") {
                    appState.pauseResumeTTS()
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Stop (⌘.)") {
                    appState.stopTTS()
                }
                .keyboardShortcut(".", modifiers: .command)
                .buttonStyle(.borderedProminent)

            case .paused:
                Button("Resume (⌘P)") {
                    appState.pauseResumeTTS()
                }
                .keyboardShortcut("p", modifiers: .command)
                .buttonStyle(.borderedProminent)

                Button("Stop (⌘.)") {
                    appState.stopTTS()
                }
                .keyboardShortcut(".", modifiers: .command)

            case .loading:
                Button("Cancel (⌘.)") {
                    appState.stopTTS()
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
