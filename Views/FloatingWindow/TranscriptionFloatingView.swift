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

/// Window selector button (dropdown trigger only)
struct WindowSelectorButton: View {
    @ObservedObject var floatingWindowManager: FloatingWindowManager
    let isExpanded: Bool
    let onToggle: () -> Void
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared

    private var targetSelectShortcut: CustomShortcut {
        shortcutManager.shortcut(for: .sttTargetSelect)
    }

    var body: some View {
        Button(action: onToggle) {
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
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .applyCustomShortcut(targetSelectShortcut)
    }
}

/// Dropdown list for window selector with keyboard navigation
struct WindowSelectorDropdown: View {
    @ObservedObject var floatingWindowManager: FloatingWindowManager
    @Binding var isExpanded: Bool
    @State private var focusedIndex: Int = 0
    @FocusState private var isListFocused: Bool

    private var totalItemCount: Int {
        floatingWindowManager.availableWindows.count + 1
    }

    private var clipboardIndex: Int {
        floatingWindowManager.availableWindows.count
    }

    /// Currently focused window for thumbnail preview
    private var focusedWindow: WindowInfo? {
        guard focusedIndex < floatingWindowManager.availableWindows.count else { return nil }
        return floatingWindowManager.availableWindows[focusedIndex]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Thumbnail preview bubble (always show container for consistent width)
            VStack(spacing: 4) {
                if let window = focusedWindow, let thumbnail = window.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 160, height: 120)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                    Text(window.ownerName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    // Clipboard or no thumbnail - show placeholder
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor.opacity(0.5))
                        .frame(width: 160, height: 120)
                    Text(focusedIndex == clipboardIndex ? "Clipboard" : "No Preview")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(Color(.windowBackgroundColor))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)

            // Dropdown list
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        // Top spacer for scroll margin
                        Color.clear
                            .frame(height: 4)
                            .id("top")

                        ForEach(Array(floatingWindowManager.availableWindows.enumerated()), id: \.element.id) { index, window in
                            WindowRowView(
                                window: window,
                                isSelected: !floatingWindowManager.clipboardOnly && floatingWindowManager.selectedWindow?.id == window.id,
                                isFocused: index == focusedIndex,
                                onSelect: { selectWindowAndClose(window) }
                            )
                            .id(index)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        ClipboardRowView(
                            isSelected: floatingWindowManager.clipboardOnly,
                            isFocused: focusedIndex == clipboardIndex,
                            onSelect: { selectClipboardAndClose() }
                        )
                        .id(clipboardIndex)

                        // Bottom spacer for scroll margin
                        Color.clear
                            .frame(height: 4)
                            .id("bottom")
                    }
                    .padding(8)
                }
                .frame(maxHeight: 300)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                .focusable()
                .focused($isListFocused)
                .onKeyPress(.upArrow) {
                    moveFocus(by: -1, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveFocus(by: 1, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.return) {
                    selectFocusedAndClose()
                    return .handled
                }
                .onKeyPress(.escape) {
                    isExpanded = false
                    return .handled
                }
                .onAppear {
                    // Set initial focus to current selection
                    if floatingWindowManager.clipboardOnly {
                        focusedIndex = clipboardIndex
                    } else if let selected = floatingWindowManager.selectedWindow,
                       let index = floatingWindowManager.availableWindows.firstIndex(where: { $0.id == selected.id }) {
                        focusedIndex = index
                    } else {
                        focusedIndex = 0
                    }
                    // Focus the list for keyboard navigation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isListFocused = true
                        // Scroll to initial selection
                        if self.focusedIndex == 0 {
                            proxy.scrollTo("top", anchor: .top)
                        } else if self.focusedIndex == self.totalItemCount - 1 {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        } else {
                            proxy.scrollTo(self.focusedIndex, anchor: nil)
                        }
                    }
                }
            }
        }
    }

    private func moveFocus(by offset: Int, proxy: ScrollViewProxy) {
        guard totalItemCount > 0 else { return }
        let newIndex = focusedIndex + offset
        // Don't wrap around - stop at boundaries
        if newIndex < 0 || newIndex >= totalItemCount {
            return
        }
        focusedIndex = newIndex
        // Scroll to spacer at edges to show padding
        if newIndex == 0 {
            proxy.scrollTo("top", anchor: .top)
        } else if newIndex == totalItemCount - 1 {
            proxy.scrollTo("bottom", anchor: .bottom)
        } else {
            proxy.scrollTo(focusedIndex, anchor: nil)
        }
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
        // Brief delay to show selection feedback before closing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isExpanded = false
        }
    }

    private func selectClipboardAndClose() {
        floatingWindowManager.selectClipboardOnly()
        // Brief delay to show selection feedback before closing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
            // Placeholder to match window thumbnail size
            Image(systemName: "doc.on.clipboard.fill")
                .font(.title2)
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
            } else {
                // Placeholder for alignment
                Color.clear
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 46)
        .background(backgroundColor)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

/// Individual window row in the selector with thumbnail
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
                    .lineLimit(1)
                Text(window.windowTitle.isEmpty ? " " : window.windowTitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            } else {
                // Placeholder for alignment
                Color.clear
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 46)
        .background(backgroundColor)
        .cornerRadius(4)
        .contentShape(Rectangle())
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
    @State private var isWindowSelectorExpanded: Bool = false
    @State private var dropdownId: UUID = UUID()  // Force recreate dropdown when opened
    @FocusState private var isTextEditorFocused: Bool
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared

    private var isRecording: Bool {
        appState.transcriptionState == .recording
    }

    // Shortcut helpers
    private var recordShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttRecord) }
    private var stopShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttStop) }
    private var pasteShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttPaste) }
    private var saveShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttSave) }
    private var targetSelectShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttTargetSelect) }
    private var cancelShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttCancel) }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                statusIcon
                Text(headerText)
                    .font(.headline)

                // Recording duration
                if isRecording {
                    Text(formattedDuration)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }

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
            .contentShape(Rectangle())
            .onTapGesture {
                if isWindowSelectorExpanded {
                    isWindowSelectorExpanded = false
                }
            }

            // Window selector button
            WindowSelectorButton(
                floatingWindowManager: appState.floatingWindowManager,
                isExpanded: isWindowSelectorExpanded,
                onToggle: {
                    if !isWindowSelectorExpanded {
                        appState.floatingWindowManager.refreshAvailableWindows()
                        dropdownId = UUID()  // Force recreate dropdown
                    }
                    isWindowSelectorExpanded.toggle()
                }
            )

            // Show dropdown OR text area (not both)
            if isWindowSelectorExpanded {
                // Dropdown list
                WindowSelectorDropdown(
                    floatingWindowManager: appState.floatingWindowManager,
                    isExpanded: $isWindowSelectorExpanded
                )
                .id(dropdownId)  // Force recreate to reset state
            } else {
                // Text area
                TextEditor(text: $editedText)
                    .font(.system(.body, design: .default))
                    .padding(8)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(8)
                    .frame(minHeight: 180, maxHeight: 350)
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
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 800)
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

    /// Format recording duration as MM:SS
    private var formattedDuration: String {
        let totalSeconds = Int(appState.recordingDuration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
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
                // Recording state: Stop and Paste buttons (Save not available while recording)
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
                // Not recording: Record, Save, and Paste buttons
                Button {
                    startRecordingWithAppend()
                } label: {
                    ButtonLabelWithShortcut(title: "Record", shortcut: "(\(recordShortcut.displayString))")
                }
                .applyCustomShortcut(recordShortcut)
                .buttonStyle(.borderedProminent)

                Button {
                    saveTextToFile()
                } label: {
                    ButtonLabelWithShortcut(title: "Save", shortcut: "(\(saveShortcut.displayString))")
                }
                .applyCustomShortcut(saveShortcut)
                .disabled(editedText.isEmpty)

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

    /// Save transcribed text to a file using NSSavePanel
    private func saveTextToFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "transcription.txt"
        savePanel.title = "Save Transcription"
        savePanel.message = "Choose a location to save the transcribed text"
        // Use a level higher than floating panels (popUpMenu + 1 = 102) so dialog appears above them
        savePanel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.popUpMenu.rawValue) + 2)
        // Set a reasonable size for the save panel
        savePanel.contentMinSize = NSSize(width: 400, height: 250)
        savePanel.setContentSize(NSSize(width: 500, height: 350))

        // Activate app and bring panel to front
        NSApp.activate(ignoringOtherApps: true)

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try editedText.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    #if DEBUG
                    print("Failed to save transcription: \(error)")
                    #endif
                }
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
    @State private var availableMicrophones: [AudioInputDevice] = []

    private var currentIcon: String {
        appState.selectedAudioInputSourceType.icon
    }

    private var currentLabel: String {
        switch appState.selectedAudioInputSourceType {
        case .microphone:
            // Show device name if not default
            if !appState.selectedAudioInputDeviceUID.isEmpty,
               let device = availableMicrophones.first(where: { $0.uid == appState.selectedAudioInputDeviceUID }) {
                return device.name
            }
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        case .applicationAudio:
            return availableApps.first { $0.bundleID == appState.selectedAudioAppBundleID }?.name ?? "App"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Input:")
                .font(.caption2)
                .foregroundColor(.secondary)
            inputMenu
        }
    }

    private var inputMenu: some View {
        Menu {
            // Microphone submenu with device selection
            Menu {
                ForEach(availableMicrophones) { device in
                    Button(action: {
                        appState.selectedAudioInputSourceType = .microphone
                        appState.selectedAudioInputDeviceUID = device.uid
                    }) {
                        HStack {
                            Text(device.name)
                            if appState.selectedAudioInputSourceType == .microphone &&
                               appState.selectedAudioInputDeviceUID == device.uid {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if availableMicrophones.isEmpty {
                    Text("No microphones detected")
                        .foregroundColor(.secondary)
                }
            } label: {
                HStack {
                    Label("Microphone", systemImage: AudioInputSourceType.microphone.icon)
                    if appState.selectedAudioInputSourceType == .microphone {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
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
            loadMicrophones()
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

    private func loadMicrophones() {
        availableMicrophones = appState.audioInputManager.availableInputDevices()

        // If selected device is not in the list, reset to system default
        if appState.selectedAudioInputSourceType == .microphone &&
           !appState.selectedAudioInputDeviceUID.isEmpty &&
           !availableMicrophones.contains(where: { $0.uid == appState.selectedAudioInputDeviceUID }) {
            appState.selectedAudioInputDeviceUID = ""
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
