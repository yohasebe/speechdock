import SwiftUI
import Carbon.HIToolbox

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

/// Window selector view with thumbnail preview
struct WindowSelectorView: View {
    @ObservedObject var floatingWindowManager: FloatingWindowManager
    @State private var isExpanded = false
    @State private var focusedIndex: Int = 0
    @FocusState private var isListFocused: Bool
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared

    /// Total count including clipboard option
    private var totalItemCount: Int {
        floatingWindowManager.availableWindows.count + 1  // +1 for clipboard option
    }

    /// Index of the clipboard option (last item)
    private var clipboardIndex: Int {
        floatingWindowManager.availableWindows.count
    }

    private var targetSelectShortcut: CustomShortcut {
        shortcutManager.shortcut(for: .sttTargetSelect)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main selector button - entire header is clickable
            Button(action: {
                toggleDropdown()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: floatingWindowManager.clipboardOnly ? "doc.on.clipboard" : "arrow.right.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.caption)

                    Text(floatingWindowManager.clipboardOnly ? "Copy to:" : "Paste to:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if floatingWindowManager.clipboardOnly {
                        Image(systemName: "doc.on.clipboard.fill")
                            .foregroundColor(.accentColor)
                            .font(.caption)
                        Text("Clipboard")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    } else if let selected = floatingWindowManager.selectedWindow {
                        // Thumbnail
                        if let thumbnail = selected.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 20)
                                .cornerRadius(2)
                        }

                        Text(selected.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No window selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Shortcut hint and expand/collapse indicator
                    Text(targetSelectShortcut.displayString)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor).opacity(0.5))
                .cornerRadius(isExpanded ? 0 : 4)
                .cornerRadius(4, corners: [.topLeft, .topRight])
            }
            .buttonStyle(.plain)
            .applyCustomShortcut(targetSelectShortcut)

            // Expanded window list
            if isExpanded {
                VStack(spacing: 2) {
                    // Window list
                    ForEach(Array(floatingWindowManager.availableWindows.enumerated()), id: \.element.id) { index, window in
                        WindowRowView(
                            window: window,
                            isSelected: !floatingWindowManager.clipboardOnly && floatingWindowManager.selectedWindow?.id == window.id,
                            isFocused: index == focusedIndex,
                            onSelect: {
                                selectWindowAndClose(window)
                            }
                        )
                    }

                    // Divider
                    Divider()
                        .padding(.vertical, 4)

                    // Clipboard option
                    ClipboardRowView(
                        isSelected: floatingWindowManager.clipboardOnly,
                        isFocused: focusedIndex == clipboardIndex,
                        onSelect: {
                            selectClipboardAndClose()
                        }
                    )
                }
                .padding(4)
                .frame(maxHeight: 250)
                .background(Color(.controlBackgroundColor).opacity(0.5))
                .cornerRadius(4, corners: [.bottomLeft, .bottomRight])
                .focusable()
                .focused($isListFocused)
                .onKeyPress(.upArrow) {
                    moveFocus(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveFocus(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    selectFocusedAndClose()
                    return .handled
                }
                .onKeyPress(.escape) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = false
                    }
                    return .handled
                }
            }
        }
    }

    private func toggleDropdown() {
        if !isExpanded {
            // Refresh before expanding
            floatingWindowManager.refreshAvailableWindows()
            // Set focused index to currently selected item
            if floatingWindowManager.clipboardOnly {
                focusedIndex = clipboardIndex
            } else if let selected = floatingWindowManager.selectedWindow,
               let index = floatingWindowManager.availableWindows.firstIndex(where: { $0.id == selected.id }) {
                focusedIndex = index
            } else {
                focusedIndex = 0
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
        // Focus the list after expanding
        if isExpanded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isListFocused = true
            }
        }
    }

    private func moveFocus(by offset: Int) {
        guard totalItemCount > 0 else { return }
        focusedIndex = (focusedIndex + offset + totalItemCount) % totalItemCount
    }

    private func selectFocusedAndClose() {
        if focusedIndex == clipboardIndex {
            selectClipboardAndClose()
        } else {
            let windows = floatingWindowManager.availableWindows
            guard focusedIndex < windows.count else { return }
            selectWindowAndClose(windows[focusedIndex])
        }
    }

    private func selectWindowAndClose(_ window: WindowInfo) {
        floatingWindowManager.selectWindow(window)
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded = false
        }
    }

    private func selectClipboardAndClose() {
        floatingWindowManager.selectClipboardOnly()
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded = false
        }
    }
}

/// Row for clipboard-only option
struct ClipboardRowView: View {
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void

    private var backgroundColor: Color {
        if isFocused {
            return Color.accentColor.opacity(0.2)
        } else if isSelected {
            return Color.accentColor.opacity(0.1)
        }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill")
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Clipboard")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                Text("Copy only, no paste")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .overlay(
            isFocused ?
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                : nil
        )
        .onTapGesture {
            onSelect()
        }
    }
}

/// Individual window row in the selector
struct WindowRowView: View {
    let window: WindowInfo
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void

    private var backgroundColor: Color {
        if isFocused {
            return Color.accentColor.opacity(0.2)
        } else if isSelected {
            return Color.accentColor.opacity(0.1)
        }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 8) {
            // Thumbnail
            if let thumbnail = window.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 30)
                    .cornerRadius(3)
                    .shadow(radius: 1)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 40, height: 30)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(window.ownerName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                if !window.windowTitle.isEmpty && window.windowTitle != window.ownerName {
                    Text(window.windowTitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .overlay(
            // Focus ring
            isFocused ?
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                : nil
        )
        .onTapGesture {
            onSelect()
        }
    }
}

/// Extension for corner-specific rounding
extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        return path
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
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared

    private var isRecording: Bool {
        appState.transcriptionState == .recording
    }

    // Shortcut helpers
    private var recordShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttRecord) }
    private var stopShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttStop) }
    private var pasteShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttPaste) }
    private var targetSelectShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttTargetSelect) }
    private var cancelShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttCancel) }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                statusIcon
                Text(headerText)
                    .font(.headline)
                Spacer()

                // Audio input source selector
                AudioInputSourceSelector(appState: appState)

                // Provider badge
                HStack(spacing: 4) {
                    Text("Provider:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(appState.selectedRealtimeProvider.rawValue)
                        .font(.caption2)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.2))
                .cornerRadius(4)

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .applyCustomShortcut(cancelShortcut)
                .help("Cancel (\(cancelShortcut.displayString))")
            }

            // Window selector
            WindowSelectorView(floatingWindowManager: appState.floatingWindowManager)

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
        .frame(minWidth: 480, idealWidth: 600, maxWidth: 800)
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
                // Recording state: Stop and Paste buttons
                Button {
                    AppState.shared.toggleRecording()
                } label: {
                    ButtonLabelWithShortcut(title: "Stop", shortcut: "(\(stopShortcut.displayString))")
                }
                .applyCustomShortcut(stopShortcut)
                .buttonStyle(.borderedProminent)

                if !editedText.isEmpty {
                    Button {
                        AppState.shared.stopRecordingAndInsert(editedText)
                    } label: {
                        ButtonLabelWithShortcut(title: "Paste", shortcut: "(\(pasteShortcut.displayString))")
                    }
                    .applyCustomShortcut(pasteShortcut)
                }
            } else {
                // Not recording: Record and Paste buttons
                Button {
                    startRecordingWithAppend()
                } label: {
                    ButtonLabelWithShortcut(title: "Record", shortcut: "(\(recordShortcut.displayString))")
                }
                .applyCustomShortcut(recordShortcut)
                .buttonStyle(.borderedProminent)

                Button {
                    onConfirm(editedText)
                } label: {
                    ButtonLabelWithShortcut(title: "Paste", shortcut: "(\(pasteShortcut.displayString))")
                }
                .applyCustomShortcut(pasteShortcut)
                .disabled(editedText.isEmpty)
            }
        }
    }
}

// MARK: - Custom Shortcut View Modifier

extension View {
    /// Apply a custom keyboard shortcut to a view
    @ViewBuilder
    func applyCustomShortcut(_ shortcut: CustomShortcut) -> some View {
        if let keyEquiv = shortcut.keyEquivalent {
            self.keyboardShortcut(keyEquiv, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

/// Compact audio input source selector for STT panel header
struct AudioInputSourceSelector: View {
    var appState: AppState
    @State private var isExpanded = false
    @State private var availableApps: [CapturableApplication] = []

    private var currentIcon: String {
        appState.selectedAudioInputSourceType.icon
    }

    private var currentLabel: String {
        switch appState.selectedAudioInputSourceType {
        case .microphone:
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        case .applicationAudio:
            return availableApps.first { $0.bundleID == appState.selectedAudioAppBundleID }?.name ?? "App"
        }
    }

    var body: some View {
        Menu {
            // Microphone option
            Button(action: {
                appState.selectedAudioInputSourceType = .microphone
            }) {
                Label("Microphone", systemImage: AudioInputSourceType.microphone.icon)
                if appState.selectedAudioInputSourceType == .microphone {
                    Image(systemName: "checkmark")
                }
            }

            // System Audio option
            Button(action: {
                appState.selectedAudioInputSourceType = .systemAudio
            }) {
                Label("System Audio", systemImage: AudioInputSourceType.systemAudio.icon)
                if appState.selectedAudioInputSourceType == .systemAudio {
                    Image(systemName: "checkmark")
                }
            }

            Divider()

            // App Audio submenu
            Menu {
                if availableApps.isEmpty {
                    Text("No apps detected")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(availableApps) { app in
                        Button(action: {
                            appState.selectedAudioInputSourceType = .applicationAudio
                            appState.selectedAudioAppBundleID = app.bundleID
                        }) {
                            HStack {
                                Text(app.name)
                                if appState.selectedAudioInputSourceType == .applicationAudio &&
                                   appState.selectedAudioAppBundleID == app.bundleID {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Divider()

                Button("Refresh Apps") {
                    Task {
                        await appState.systemAudioCaptureService.refreshAvailableApps()
                        availableApps = appState.systemAudioCaptureService.availableApps
                    }
                }
            } label: {
                Label("App Audio", systemImage: AudioInputSourceType.applicationAudio.icon)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentIcon)
                    .font(.caption)
                Text(currentLabel)
                    .font(.caption2)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(sourceBackgroundColor)
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .onAppear {
            Task {
                await appState.systemAudioCaptureService.refreshAvailableApps()
                availableApps = appState.systemAudioCaptureService.availableApps
            }
        }
    }

    private var sourceBackgroundColor: Color {
        switch appState.selectedAudioInputSourceType {
        case .microphone:
            return Color.blue.opacity(0.2)
        case .systemAudio:
            return Color.green.opacity(0.2)
        case .applicationAudio:
            return Color.orange.opacity(0.2)
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
