import SwiftUI

struct TranscriptionFloatingView: View {
    var appState: AppState
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var editedText: String = ""
    @FocusState private var isTextEditorFocused: Bool

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
                    // Recording indicator border when text is present
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red, lineWidth: appState.transcriptionState == .recording ? 2 : 0)
                        .opacity(appState.transcriptionState == .recording ? 1 : 0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: appState.transcriptionState == .recording)
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
        .frame(width: 450)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .onChange(of: appState.currentTranscription) { _, newValue in
            editedText = newValue
        }
        .onAppear {
            editedText = appState.currentTranscription
            // Auto-focus text editor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextEditorFocused = true
            }
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

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Cancel (⌘.)") {
                onCancel()
            }
            .keyboardShortcut(".", modifiers: .command)

            Spacer()

            if case .recording = appState.transcriptionState {
                Button("Stop (⌘S)") {
                    AppState.shared.toggleRecording()
                }
                .keyboardShortcut("s", modifiers: .command)

                if !editedText.isEmpty {
                    Button("Insert (⌘↩)") {
                        AppState.shared.stopRecordingAndInsert(editedText)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Copy All") {
                    ClipboardService.shared.copyToClipboard(editedText)
                }
                .disabled(editedText.isEmpty)

                Button("Insert (⌘↩)") {
                    onConfirm(editedText)
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
