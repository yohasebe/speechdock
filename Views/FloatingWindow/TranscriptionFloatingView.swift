import SwiftUI

/// Button label with smaller keyboard shortcut text
struct ButtonLabelWithShortcut: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            Text(shortcut)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct TranscriptionFloatingView: View {
    var appState: AppState
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var editedText: String = ""
    @State private var borderOpacity: Double = 1.0
    @State private var baseText: String = ""  // Text to preserve when resuming recording
    @FocusState private var isTextEditorFocused: Bool

    private var isRecording: Bool {
        appState.transcriptionState == .recording
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
                Text(appState.selectedRealtimeProvider.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("Cancel (⌘.)")
            }

            // Always show text area
            TextEditor(text: $editedText)
                .font(.system(.body, design: .default))
                .padding(8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)
                .frame(minHeight: 120, maxHeight: 250)
                .focused($isTextEditorFocused)
                .overlay(
                    // Placeholder text when empty and recording
                    Group {
                        if editedText.isEmpty && appState.transcriptionState == .recording {
                            VStack {
                                HStack(spacing: 4) {
                                    ForEach(0..<5, id: \.self) { index in
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.red.opacity(0.7))
                                            .frame(width: 3, height: CGFloat.random(in: 8...25))
                                    }
                                }
                                Text("Listening...")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                )
                .overlay(
                    // Recording indicator border - only exists while recording
                    Group {
                        if isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red, lineWidth: 2)
                                .opacity(borderOpacity)
                        }
                    }
                )

            // Error message if any
            if case .error(let message) = appState.transcriptionState {
                Text(message)
                    .foregroundColor(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Action buttons
            actionButtons
        }
        .padding(16)
        .frame(minWidth: 380, idealWidth: 450, maxWidth: 800)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .onChange(of: appState.currentTranscription) { _, newValue in
            // Append new transcription to base text
            if baseText.isEmpty {
                editedText = newValue
            } else if newValue.isEmpty {
                // Keep existing text when transcription is cleared
                editedText = baseText
            } else {
                // Append with space separator
                editedText = baseText + " " + newValue
            }
        }
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                // Save current text as base when recording starts
                baseText = editedText.trimmingCharacters(in: .whitespaces)
                // Start pulsing animation when recording starts
                startBorderAnimation()
            } else {
                // Update base text with current content when recording stops
                // Animation stops automatically when the overlay view is removed
                baseText = editedText.trimmingCharacters(in: .whitespaces)
            }
        }
        .onAppear {
            editedText = appState.currentTranscription
            // Auto-focus text editor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextEditorFocused = true
            }
            // Start animation if already recording
            if isRecording {
                startBorderAnimation()
            }
        }
    }

    private func startBorderAnimation() {
        borderOpacity = 1.0
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            borderOpacity = 0.3
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        Group {
            switch appState.transcriptionState {
            case .recording:
                Image(systemName: "mic.fill")
                    .foregroundColor(.red)
                    .symbolEffect(.pulse)
            case .processing:
                ProgressView()
                    .scaleEffect(0.8)
            case .result:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            case .idle:
                Image(systemName: "waveform")
                    .foregroundColor(.accentColor)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var headerText: String {
        switch appState.transcriptionState {
        case .recording:
            return "Recording..."
        case .processing:
            return "Processing..."
        case .result:
            return "Done"
        case .error:
            return "Error"
        case .idle:
            return "Ready"
        }
    }

    private func startRecordingWithAppend() {
        // Save current text BEFORE starting recording
        baseText = editedText.trimmingCharacters(in: .whitespaces)
        AppState.shared.toggleRecording()
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Spacer()

            if case .recording = appState.transcriptionState {
                // Recording state: Stop and Insert buttons
                Button {
                    AppState.shared.toggleRecording()
                } label: {
                    ButtonLabelWithShortcut(title: "Stop", shortcut: "(⌘S)")
                }
                .keyboardShortcut("s", modifiers: .command)

                if !editedText.isEmpty {
                    Button {
                        AppState.shared.stopRecordingAndInsert(editedText)
                    } label: {
                        ButtonLabelWithShortcut(title: "Insert", shortcut: "(⌘↩)")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // Not recording: Record, Copy, Insert buttons
                Button {
                    startRecordingWithAppend()
                } label: {
                    ButtonLabelWithShortcut(title: "Record", shortcut: "(⌘R)")
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Copy") {
                    ClipboardService.shared.copyToClipboard(editedText)
                }
                .disabled(editedText.isEmpty)

                Button {
                    onConfirm(editedText)
                } label: {
                    ButtonLabelWithShortcut(title: "Insert", shortcut: "(⌘↩)")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(editedText.isEmpty)
            }
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
