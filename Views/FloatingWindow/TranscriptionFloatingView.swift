import SwiftUI
import Carbon.HIToolbox

/// Button label with icon and keyboard shortcut text
struct ButtonLabelWithShortcut: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let shortcut: String
    var icon: String? = nil
    var isProminent: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.body)
            }
            Text(title)
                .font(.body)
            Text(shortcut)
                .font(.callout)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}

/// Compact button label for grouped buttons (smaller font)
struct CompactButtonLabel: View {
    let title: String
    let shortcut: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.callout)
            }
            Text(title)
                .font(.callout)
            Text("(\(shortcut))")
                .font(.caption)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
    }
}

/// Compact window selector button for action bar (triggers popover)
struct CompactWindowSelectorButton: View {
    @ObservedObject var floatingWindowManager: FloatingWindowManager
    @Binding var isExpanded: Bool
    let onToggle: () -> Void
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared

    private var targetSelectShortcut: CustomShortcut {
        shortcutManager.shortcut(for: .sttTargetSelect)
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 3) {
                Image(systemName: "macwindow")
                    .font(.callout)

                Text("Target:")
                    .font(.callout)

                if let selected = floatingWindowManager.selectedWindow {
                    if let appIcon = selected.appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.callout)
                    }
                } else {
                    Text("None")
                        .font(.callout)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .applyCustomShortcut(targetSelectShortcut)
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
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.callout)

                Text("Paste Target:")
                    .font(.callout)
                    .foregroundColor(.secondary)

                if let selected = floatingWindowManager.selectedWindow {
                    // App icon (larger, no thumbnail)
                    if let appIcon = selected.appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                    }
                    Text(selected.displayName)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No window selected")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(targetSelectShortcut.displayString)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.callout)
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
        floatingWindowManager.availableWindows.count
    }

    /// Currently focused window for thumbnail preview
    private var focusedWindow: WindowInfo? {
        guard focusedIndex < floatingWindowManager.availableWindows.count else { return nil }
        return floatingWindowManager.availableWindows[focusedIndex]
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                // Thumbnail preview bubble (50% width)
                VStack(spacing: 4) {
                    if let window = focusedWindow {
                        if let thumbnail = window.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 180)
                                .cornerRadius(8)
                                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                        } else {
                            // Loading placeholder
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: 180)
                        }
                        Text(window.ownerName)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        // No window selected - show placeholder
                        Image(systemName: "macwindow")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                            .frame(maxWidth: .infinity, maxHeight: 180)
                        Text("No Preview")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
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
                                isSelected: floatingWindowManager.selectedWindow?.id == window.id,
                                isFocused: index == focusedIndex,
                                onSelect: { selectWindowAndClose(window) }
                            )
                            .id(index)
                        }

                        // Bottom spacer for scroll margin
                        Color.clear
                            .frame(height: 4)
                            .id("bottom")
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: 300)
                .background(Color(.windowBackgroundColor))
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                .focusable()
                .focused($isListFocused)
                .onChange(of: focusedIndex) { _, newIndex in
                    // Load thumbnail for focused window if not yet loaded
                    if newIndex < floatingWindowManager.availableWindows.count {
                        let window = floatingWindowManager.availableWindows[newIndex]
                        floatingWindowManager.loadThumbnailIfNeeded(for: window.id)
                    }
                }
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
                    if let selected = floatingWindowManager.selectedWindow,
                       let index = floatingWindowManager.availableWindows.firstIndex(where: { $0.id == selected.id }) {
                        focusedIndex = index
                    } else {
                        focusedIndex = 0
                    }
                    // Load thumbnail for initially focused window
                    if focusedIndex < floatingWindowManager.availableWindows.count {
                        let window = floatingWindowManager.availableWindows[focusedIndex]
                        floatingWindowManager.loadThumbnailIfNeeded(for: window.id)
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

            // Keyboard navigation hint
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.callout)
                Text("Use arrow keys to preview")
                    .font(.callout)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 8)
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
        let windows = floatingWindowManager.availableWindows
        guard focusedIndex < windows.count else { return }
        selectWindowAndClose(windows[focusedIndex])
    }

    private func selectWindowAndClose(_ window: WindowInfo) {
        floatingWindowManager.selectWindow(window)
        // Brief delay to show selection feedback before closing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isExpanded = false
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
            // App icon (larger, no inline thumbnail - preview shown on left side)
            if let appIcon = window.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 24))
                    .frame(width: 28, height: 28)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(window.ownerName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(window.windowTitle.isEmpty ? " " : window.windowTitle)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.callout)
                    .foregroundColor(.accentColor)
            } else {
                // Placeholder for alignment
                Color.clear
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 42)
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

/// Animated loading indicator for STT transcription processing (matches "Listening..." style)
struct STTLoadingIndicator: View {
    @State private var animationPhase: Double = 0

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4
    private let minHeight: CGFloat = 8
    private let maxHeight: CGFloat = 25

    var body: some View {
        VStack(spacing: 6) {
            // Animated waveform bars (blue color for processing)
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: barWidth, height: barHeight(for: index))
                }
            }
            .frame(height: maxHeight)

            Text("Transcribing...")
                .foregroundColor(.secondary)
                .font(.callout)
        }
        .onAppear {
            startAnimation()
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Create wave effect with phase offset for each bar
        let phaseOffset = Double(index) * 0.5
        let wave = sin(animationPhase + phaseOffset)
        let normalizedWave = (wave + 1) / 2  // Convert from -1...1 to 0...1
        return minHeight + (maxHeight - minHeight) * CGFloat(normalizedWave)
    }

    private func startAnimation() {
        // Continuous animation loop
        withAnimation(
            .linear(duration: 1.0)
            .repeatForever(autoreverses: false)
        ) {
            animationPhase = .pi * 2
        }
    }
}

/// Audio level indicator bars for STT panel (fixed height container)
struct AudioLevelIndicator: View {
    @ObservedObject var audioLevelMonitor = AudioLevelMonitor.shared
    let barCount: Int = 5
    let barWidth: CGFloat = 3
    let containerHeight: CGFloat = 16  // Fixed container height
    let maxBarHeight: CGFloat = 14
    let minBarHeight: CGFloat = 4

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: index))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .frame(height: containerHeight)  // Fixed container height
        .animation(.easeOut(duration: 0.1), value: audioLevelMonitor.level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = audioLevelMonitor.level
        // Each bar has a threshold - bars light up progressively
        let threshold = Float(index) / Float(barCount)
        let barLevel = max(0, min(1, (level - threshold) / (1.0 / Float(barCount))))
        return minBarHeight + CGFloat(barLevel) * (maxBarHeight - minBarHeight)
    }

    private func barColor(for index: Int) -> Color {
        let level = audioLevelMonitor.level
        let threshold = Float(index) / Float(barCount)

        if level > threshold {
            // Color gradient: green -> yellow -> red
            if index < 2 {
                return .green
            } else if index < 4 {
                return .yellow
            } else {
                return .red
            }
        } else {
            return Color.gray.opacity(0.3)
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
    @State private var isWindowSelectorExpanded: Bool = false
    @State private var dropdownId: UUID = UUID()  // Force recreate dropdown when opened
    @State private var showCopiedFeedback: Bool = false
    @State private var isDragOver: Bool = false  // Track drag over state for file drop
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared
    @StateObject private var audioLevelMonitor = AudioLevelMonitor.shared

    private var isRecording: Bool {
        appState.transcriptionState == .recording || appState.transcriptionState == .preparing
    }

    private var isTranscribingFile: Bool {
        appState.transcriptionState == .transcribingFile
    }

    /// Whether any transcription activity is happening (recording or file transcription)
    private var isBusy: Bool {
        isRecording || isTranscribingFile
    }

    // Shortcut helpers
    private var recordShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttRecord) }
    private var stopShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttStop) }
    private var pasteShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttPaste) }
    private var saveShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttSave) }
    private var targetSelectShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttTargetSelect) }
    private var cancelShortcut: CustomShortcut { shortcutManager.shortcut(for: .sttCancel) }
    private var fontSizeIncreaseShortcut: CustomShortcut { shortcutManager.shortcut(for: .fontSizeIncrease) }
    private var fontSizeDecreaseShortcut: CustomShortcut { shortcutManager.shortcut(for: .fontSizeDecrease) }
    private var fontSizeResetShortcut: CustomShortcut { shortcutManager.shortcut(for: .fontSizeReset) }

    // Panel style helpers
    private var isFloatingStyle: Bool { appState.panelStyle == .floating }
    private var panelCornerRadius: CGFloat { isFloatingStyle ? 12 : 0 }

    @ViewBuilder
    private var panelBackground: some View {
        if isFloatingStyle {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
        } else {
            Color(NSColor.windowBackgroundColor)
        }
    }

    /// Border overlay for text area
    private var textAreaBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    }

    /// Placeholder overlay when text area is empty
    @ViewBuilder
    private var placeholderOverlay: some View {
        if editedText.isEmpty {
            if isRecording {
                // Recording state placeholders
                if appState.transcriptionState == .preparing {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Starting...")
                            .foregroundColor(.secondary)
                            .font(.callout)
                    }
                } else {
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
                            .font(.callout)
                    }
                }
            } else if !isTranscribingFile {
                // Idle state - prompt user to start recording or drop a file
                let recordShortcut = ShortcutSettingsManager.shared.shortcut(for: .sttRecord)
                let provider = appState.selectedRealtimeProvider

                VStack(spacing: 12) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Press Record (\(recordShortcut.displayString)) to start transcription")
                        .foregroundColor(.secondary)
                        .font(.callout)

                    // File drop hint - only show if provider supports file transcription
                    if provider.supportsFileTranscription {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.caption)
                                Text("Or drop an audio file here")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary.opacity(0.7))

                            // Provider-specific limits
                            Text("\(provider.supportedAudioFormats) (max \(provider.maxFileSizeMB)MB, \(provider.maxAudioDuration))")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    } else {
                        // Show hint about switching provider for file transcription
                        Text("Switch to OpenAI, Gemini, or ElevenLabs for file transcription")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }
        }
    }

    /// Recording indicator border overlay
    @ViewBuilder
    private var recordingBorderOverlay: some View {
        if isRecording {
            let borderColor = appState.transcriptionState == .preparing ? Color.orange : Color.red
            let opacity = appState.transcriptionState == .preparing ? 1.0 : borderOpacity
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 2)
                .opacity(opacity)
        }
    }

    /// File transcription progress overlay
    @ViewBuilder
    private var fileTranscriptionOverlay: some View {
        if isTranscribingFile {
            ZStack {
                Color.black.opacity(0.3)
                    .cornerRadius(8)
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Transcribing file...")
                        .font(.callout)
                        .foregroundColor(.white)
                    Button("Cancel") {
                        appState.cancelFileTranscription()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
                .background(Color(.windowBackgroundColor).opacity(0.95))
                .cornerRadius(12)
                .shadow(radius: 10)
            }
        }
    }

    /// Drag over indicator overlay
    @ViewBuilder
    private var dragOverOverlay: some View {
        if isDragOver && !isBusy {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.1))
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)
                    Text("Drop audio file to transcribe")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    /// Handle audio file drop
    private func handleAudioFileDrop(_ providers: [NSItemProvider]) -> Bool {
        // Don't accept drops while recording or transcribing
        guard !isBusy else { return false }

        for provider in providers {
            // Try to load as file URL
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    if let error = error {
                        #if DEBUG
                        print("Drop error: \(error)")
                        #endif
                        return
                    }

                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        return
                    }

                    // Check if it's an audio file
                    let audioExtensions = ["mp3", "wav", "m4a", "aac", "webm", "ogg", "flac", "mp4"]
                    let ext = url.pathExtension.lowercased()
                    guard audioExtensions.contains(ext) else {
                        Task { @MainActor in
                            let provider = appState.selectedRealtimeProvider
                            let formats = provider.supportsFileTranscription ? provider.supportedAudioFormats : "MP3, WAV, M4A, AAC, WebM, OGG, FLAC"
                            showDropNotice("Unsupported file format: .\(ext)\n\nSupported formats: \(formats)")
                        }
                        return
                    }

                    // Start transcription on main thread
                    Task { @MainActor in
                        appState.transcribeAudioFile(url)
                    }
                }
                return true
            }
        }
        return false
    }

    /// Show notification alert for drop issues
    private func showDropNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "File Transcription"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        alert.window.level = .floating + 1

        alert.runModal()
    }

    /// Floating action buttons inside text area (Font size, Spell Check, Clear)
    @ViewBuilder
    private var textAreaFloatingButtons: some View {
        // Only show when not busy and text is not empty
        if !isBusy && !editedText.isEmpty {
            HStack(spacing: 6) {
                // Font size stepper
                HStack(spacing: 2) {
                    // Decrease font size
                    Button(action: {
                        appState.decreasePanelTextFontSize()
                    }) {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Decrease Font Size (\(shortcutManager.shortcut(for: .fontSizeDecrease).displayString))")

                    // Current size (click to reset)
                    Button(action: {
                        appState.resetPanelTextFontSize()
                    }) {
                        Text("\(Int(appState.panelTextFontSize))")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(minWidth: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Reset Font Size (\(shortcutManager.shortcut(for: .fontSizeReset).displayString))")

                    // Increase font size
                    Button(action: {
                        appState.increasePanelTextFontSize()
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Increase Font Size (\(shortcutManager.shortcut(for: .fontSizeIncrease).displayString))")
                }

                Divider()
                    .frame(height: 12)

                // Spell Check button
                Button(action: {
                    showSpellingPanel()
                }) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Spell Check")

                // Clear button
                Button(action: {
                    editedText = ""
                    baseText = ""
                }) {
                    Image(systemName: "eraser")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Text")
            }
            .padding(6)
            .background(Color(.windowBackgroundColor).opacity(0.9))
            .cornerRadius(6)
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            .padding(8)
        }
    }

    /// Translation controls (left side of text area)
    @ViewBuilder
    private var translationControlsView: some View {
        // Don't show translation controls when recording or transcribing
        if !isBusy {
            TranslationControls(
                appState: appState,
                text: displayTextForTranslation,
                onTranslate: { translatedText in
                    editedText = translatedText
                }
            )
            .padding(8)
        }
    }

    /// Text to use for translation - always use original text, not translated text
    private var displayTextForTranslation: String {
        // When already translated, use the saved original for re-translation
        // This prevents originalTextBeforeTranslation from being corrupted
        if appState.translationState.isTranslated && !appState.originalTextBeforeTranslation.isEmpty {
            return appState.originalTextBeforeTranslation
        }
        return editedText
    }

    /// Show the macOS spelling panel and check spelling
    private func showSpellingPanel() {
        // Use the shared holder to trigger spell check on the panel text view
        PanelTextViewHolder.shared.triggerSpellCheck()
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                // Only show close button in floating mode (standard window has title bar close button)
                if isFloatingStyle {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .applyCustomShortcut(cancelShortcut)
                    .keyboardShortcut("w", modifiers: .command)
                    .help("Close (⌘W)")
                }

                statusIcon
                Text(headerText)
                    .font(.headline)

                // Subtitle mode indicator
                if appState.subtitleModeEnabled {
                    HStack(spacing: 4) {
                        Image(systemName: "captions.bubble.fill")
                            .font(.system(size: 10))
                        Text("Subtitle")
                            .font(.callout)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.8))
                    .cornerRadius(4)
                }

                // Recording duration and audio level
                if isRecording {
                    HStack(spacing: 8) {
                        // Audio level indicator
                        AudioLevelIndicator()

                        // Duration
                        Text(formattedDuration)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
                }

                Spacer()

                // Provider selector
                STTProviderSelector(appState: appState)
                    .disabled(isRecording)

                // Language selector
                STTLanguageSelector(appState: appState)
                    .disabled(isRecording)

                // Input selector
                AudioInputSourceSelector(appState: appState)
                    .disabled(appState.isRecording)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isWindowSelectorExpanded {
                    isWindowSelectorExpanded = false
                }
            }

            // Text area with replacement highlighting
            // Disable editing during recording/file transcription or when showing translated text
            ScrollableTextView(
                    text: $editedText,
                    isEditable: !isBusy && !appState.translationState.isTranslated,
                    highlightRange: nil,
                    enableHighlight: false,
                    showReplacementHighlights: true,
                    fontSize: CGFloat(appState.panelTextFontSize),
                    autoScrollToBottom: isRecording  // Auto-scroll while recording
                )
                .background(appState.translationState.isTranslated
                    ? Color.blue.opacity(0.15)
                    : Color(.textBackgroundColor))
                .cornerRadius(8)
                .overlay(textAreaBorder)
                .frame(minHeight: 180, maxHeight: .infinity)
                .overlay(placeholderOverlay)
                .overlay(recordingBorderOverlay)
                .overlay(fileTranscriptionOverlay)
                .overlay(
                    // Transcription processing overlay
                    Group {
                        if case .processing = appState.transcriptionState {
                            STTLoadingIndicator()
                        }
                    }
                )
                .overlay(alignment: .bottomLeading) {
                    // Translation controls (left side)
                    translationControlsView
                }
                .overlay(alignment: .bottomTrailing) {
                    // Floating action buttons (Clear, Spell Check)
                    textAreaFloatingButtons
                }
                .overlay(dragOverOverlay)
                .onDrop(of: [.audio, .fileURL], isTargeted: $isDragOver) { providers in
                    handleAudioFileDrop(providers)
                }

                // Error message if any
                if case .error(let message) = appState.transcriptionState {
                    Text(message)
                        .foregroundColor(.red)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            // Action buttons
            actionButtons
        }
        .padding(16)
        .frame(minWidth: 820, idealWidth: 900, maxWidth: .infinity)
        .background(panelBackground)
        .cornerRadius(panelCornerRadius)
        .onChange(of: appState.currentTranscription) { _, newValue in
            // Update editedText during recording (append mode)
            if isRecording {
                // Append new transcription to base text
                if baseText.isEmpty {
                    editedText = newValue
                } else if newValue.isEmpty {
                    editedText = baseText
                } else {
                    editedText = baseText + " " + newValue
                }
            }
        }
        .onChange(of: appState.transcriptionState) { oldState, newState in
            // Handle file transcription result
            if case .result(let text) = newState,
               case .transcribingFile = oldState {
                // File transcription completed - set the result text
                editedText = text
            }
        }
        .onChange(of: appState.translationState) { oldState, newState in
            // Handle translation state changes
            switch newState {
            case .translated(let translatedText):
                // Resign first responder to allow text update through ScrollableTextView
                NSApp.keyWindow?.makeFirstResponder(nil)
                // Show translated text
                editedText = translatedText
                #if DEBUG
                print("TranscriptionFloatingView: Translation complete, editedText updated to length \(translatedText.count)")
                #endif
            case .idle:
                // When reverting to original, restore original text
                if oldState.isTranslated && !appState.originalTextBeforeTranslation.isEmpty {
                    // Resign first responder to allow text update
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    editedText = appState.originalTextBeforeTranslation
                    #if DEBUG
                    print("TranscriptionFloatingView: Reverted to original text")
                    #endif
                }
            case .error(let message):
                #if DEBUG
                print("TranscriptionFloatingView: Translation error: \(message)")
                #endif
            case .translating:
                break
            }
        }
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                // Recording started - sync editedText to currentTranscription for subtitle panel
                appState.currentTranscription = editedText
                // Save current text as base
                baseText = editedText.trimmingCharacters(in: .whitespaces)
                startBorderAnimation()
            } else {
                // Recording stopped
                baseText = editedText.trimmingCharacters(in: .whitespaces)
                appState.currentTranscription = editedText
            }
        }
        .onAppear {
            editedText = appState.currentTranscription
            // Start animation if already recording
            if isRecording {
                startBorderAnimation()
            }
        }
        // Font size shortcuts (invisible buttons)
        .background {
            Group {
                Button("") { appState.increasePanelTextFontSize() }
                    .applyCustomShortcut(fontSizeIncreaseShortcut)
                    .keyboardShortcut("+", modifiers: .command)  // Also support ⌘+ (shift+=)
                Button("") { appState.decreasePanelTextFontSize() }
                    .applyCustomShortcut(fontSizeDecreaseShortcut)
                Button("") { appState.resetPanelTextFontSize() }
                    .applyCustomShortcut(fontSizeResetShortcut)
            }
            .opacity(0)
            .allowsHitTesting(false)
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
            case .preparing:
                ProgressView()
                    .scaleEffect(0.6)
            case .recording:
                Image(systemName: "mic.fill")
                    .foregroundColor(.red)
                    .symbolEffect(.pulse)
            case .transcribingFile:
                ProgressView()
                    .scaleEffect(0.6)
            case .processing:
                Image(systemName: "text.badge.checkmark")
                    .foregroundColor(.accentColor)
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
        case .preparing:
            return "Starting..."
        case .recording:
            return "Recording..."
        case .transcribingFile:
            return "Transcribing File..."
        case .processing:
            return "Processing..."
        case .result:
            return "Ready"  // User can continue recording or paste
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
            // Subtitle mode toggle (wrapped to match Target+Paste group height)
            HStack {
                Button(action: {
                    appState.toggleSubtitleMode()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: appState.subtitleModeEnabled ? "captions.bubble.fill" : "captions.bubble")
                            .font(.callout)
                        Text("Subtitle")
                            .font(.callout)
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(appState.subtitleModeEnabled ? .accentColor : nil)
                .help(appState.subtitleModeEnabled ? "Subtitle Mode: On (⌃⌥S)" : "Subtitle Mode: Off (⌃⌥S)")
                .disabled(isTranscribingFile)
            }
            .padding(3)
            .background(Color.clear)
            .cornerRadius(8)

            // Target + Paste group
            HStack(spacing: 2) {
                // Target selector
                CompactWindowSelectorButton(
                    floatingWindowManager: appState.floatingWindowManager,
                    isExpanded: $isWindowSelectorExpanded,
                    onToggle: {
                        if !isWindowSelectorExpanded {
                            appState.floatingWindowManager.refreshAvailableWindows()
                            dropdownId = UUID()
                        }
                        isWindowSelectorExpanded.toggle()
                    }
                )
                .popover(isPresented: $isWindowSelectorExpanded) {
                    WindowSelectorDropdown(
                        floatingWindowManager: appState.floatingWindowManager,
                        isExpanded: $isWindowSelectorExpanded
                    )
                    .id(dropdownId)
                    .frame(width: 500, height: 400)
                    .padding()
                }

                // Paste button
                if case .recording = appState.transcriptionState {
                    if !editedText.isEmpty {
                        Button {
                            AppState.shared.stopRecordingAndInsert(editedText)
                        } label: {
                            CompactButtonLabel(title: "Paste", shortcut: pasteShortcut.displayString, icon: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .applyCustomShortcut(pasteShortcut)
                    }
                } else {
                    Button {
                        onConfirm(editedText)
                    } label: {
                        CompactButtonLabel(title: "Paste", shortcut: pasteShortcut.displayString, icon: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .applyCustomShortcut(pasteShortcut)
                    .disabled(editedText.isEmpty || isTranscribingFile)
                }
            }
            .padding(3)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Spacer()

            if case .recording = appState.transcriptionState {
                // Recording state: Stop and Copy buttons
                Button {
                    AppState.shared.toggleRecording()
                } label: {
                    ButtonLabelWithShortcut(title: "Stop", shortcut: "(\(stopShortcut.displayString))", icon: "stop.fill", isProminent: true)
                }
                .applyCustomShortcut(stopShortcut)
                .buttonStyle(.borderedProminent)

                if !editedText.isEmpty {
                    Button {
                        copyTextToClipboard()
                    } label: {
                        ButtonLabelWithShortcut(
                            title: showCopiedFeedback ? "Copied!" : "Copy",
                            shortcut: showCopiedFeedback ? "" : "(⌘⇧C)",
                            icon: showCopiedFeedback ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            } else if isTranscribingFile {
                // File transcription in progress: Cancel button only
                Button {
                    appState.cancelFileTranscription()
                } label: {
                    ButtonLabelWithShortcut(title: "Cancel", shortcut: "(Esc)", icon: "xmark", isProminent: false)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                // Not recording: Record, Save, and Copy buttons
                Button {
                    startRecordingWithAppend()
                } label: {
                    ButtonLabelWithShortcut(title: "Record", shortcut: "(\(recordShortcut.displayString))", icon: "mic.fill", isProminent: true)
                }
                .applyCustomShortcut(recordShortcut)
                .buttonStyle(.borderedProminent)

                Button {
                    saveTextToFile()
                } label: {
                    ButtonLabelWithShortcut(title: "Save Text", shortcut: "(\(saveShortcut.displayString))", icon: "square.and.arrow.down")
                }
                .applyCustomShortcut(saveShortcut)
                .disabled(editedText.isEmpty)

                Button {
                    copyTextToClipboard()
                } label: {
                    ButtonLabelWithShortcut(
                        title: showCopiedFeedback ? "Copied!" : "Copy",
                        shortcut: showCopiedFeedback ? "" : "(⌘⇧C)",
                        icon: showCopiedFeedback ? "checkmark" : "doc.on.doc"
                    )
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(editedText.isEmpty)
            }
        }
    }

    /// Copy all text to clipboard
    private func copyTextToClipboard() {
        guard !editedText.isEmpty else { return }
        let processedText = TextReplacementService.shared.applyReplacements(to: editedText)
        ClipboardService.shared.copyToClipboard(processedText)

        // Show "Copied!" feedback
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedFeedback = false
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
        WindowLevelCoordinator.configureSavePanel(savePanel)

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

    /// Get the current app icon for App Audio mode
    private var currentAppIcon: NSImage? {
        guard appState.selectedAudioInputSourceType == .applicationAudio else { return nil }
        return availableApps.first { $0.bundleID == appState.selectedAudioAppBundleID }?.icon
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
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize()
            inputMenu
        }
        .fixedSize()
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
                    // Show recently used apps first with a section header if there are any
                    let recentApps = availableApps.filter { $0.isRecentlyUsed }
                    let otherApps = availableApps.filter { !$0.isRecentlyUsed }

                    if !recentApps.isEmpty {
                        Section("Recent") {
                            ForEach(recentApps) { app in
                                appAudioButton(for: app)
                            }
                        }

                        if !otherApps.isEmpty {
                            Divider()
                        }
                    }

                    ForEach(otherApps) { app in
                        appAudioButton(for: app)
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
                // Show app icon for App Audio, system icon for others
                // Use same size as Target selector (16x16)
                if let appIcon = currentAppIcon {
                    Image(nsImage: resizedIcon(appIcon, to: NSSize(width: 16, height: 16)))
                } else {
                    Image(systemName: currentIcon)
                        .frame(width: 16, height: 16)
                }
                Text(currentLabel)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(sourceBackgroundColor)
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear {
            loadMicrophones()
            Task {
                await appState.systemAudioCaptureService.refreshAvailableApps()
                availableApps = appState.systemAudioCaptureService.availableApps
            }
        }
    }

    @ViewBuilder
    private func appAudioButton(for app: CapturableApplication) -> some View {
        Button(action: {
            appState.selectedAudioInputSourceType = .applicationAudio
            appState.selectedAudioAppBundleID = app.bundleID
            appState.systemAudioCaptureService.recordAppUsage(bundleID: app.bundleID)
            // Refresh to update recently used status
            Task {
                await appState.systemAudioCaptureService.refreshAvailableApps()
                availableApps = appState.systemAudioCaptureService.availableApps
            }
        }) {
            HStack {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
                Text(app.name)
                if appState.selectedAudioInputSourceType == .applicationAudio &&
                   appState.selectedAudioAppBundleID == app.bundleID {
                    Spacer()
                    Image(systemName: "checkmark")
                }
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

    /// Resize NSImage to a fixed size
    private func resizedIcon(_ image: NSImage, to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
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

/// Compact STT provider selector for panel header
struct STTProviderSelector: View {
    var appState: AppState

    private var availableProviders: [RealtimeSTTProvider] {
        RealtimeSTTProvider.allCases.filter { provider in
            !provider.requiresAPIKey || hasAPIKey(for: provider)
        }
    }

    private func hasAPIKey(for provider: RealtimeSTTProvider) -> Bool {
        switch provider {
        case .openAI:
            return appState.apiKeyManager.hasAPIKey(for: .openAI)
        case .gemini:
            return appState.apiKeyManager.hasAPIKey(for: .gemini)
        case .elevenLabs:
            return appState.apiKeyManager.hasAPIKey(for: .elevenLabs)
        case .grok:
            return appState.apiKeyManager.hasAPIKey(for: .grok)
        case .macOS:
            return true
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Provider:")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize()
            Menu {
                ForEach(availableProviders, id: \.rawValue) { provider in
                    Button(action: {
                        appState.selectedRealtimeProvider = provider
                    }) {
                        HStack {
                            Text(provider.rawValue)
                            if appState.selectedRealtimeProvider == provider {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(appState.selectedRealtimeProvider.rawValue)
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .fixedSize()
    }
}

/// Compact STT language selector for panel header
struct STTLanguageSelector: View {
    var appState: AppState

    private var availableLanguages: [LanguageCode] {
        LanguageCode.supportedLanguages(for: appState.selectedRealtimeProvider)
    }

    private var currentLanguageDisplay: String {
        if appState.selectedSTTLanguage.isEmpty {
            return "Auto"
        }
        if let lang = LanguageCode(rawValue: appState.selectedSTTLanguage) {
            return lang.displayName
        }
        return "Auto"
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Language:")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize()
            Menu {
                ForEach(availableLanguages, id: \.rawValue) { lang in
                    Button(action: {
                        appState.selectedSTTLanguage = lang.rawValue
                    }) {
                        HStack {
                            Text(lang.displayName)
                            if appState.selectedSTTLanguage == lang.rawValue {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(currentLanguageDisplay)
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.2))
                    .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .fixedSize()
    }
}
