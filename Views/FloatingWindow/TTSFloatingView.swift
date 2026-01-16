import SwiftUI
import Carbon.HIToolbox

/// Custom NSTextView subclass for TTS input
class FocusableTextView: NSTextView {
    // Focus is handled by FloatingWindowManager via didBecomeKeyNotification
}

/// TTS state for the floating view
enum TTSState: Equatable {
    case idle
    case speaking
    case paused
    case loading
    case error(String)
}

/// NSTextView wrapper that allows scrolling even when not editable
struct ScrollableTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var highlightRange: NSRange?  // Kept for API compatibility, but not used
    var enableHighlight: Bool  // Kept for API compatibility, but not used
    var showReplacementHighlights: Bool = true
    var fontSize: CGFloat = NSFont.systemFontSize
    var autoScrollToBottom: Bool = false  // Auto-scroll when text changes

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = FocusableTextView()

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Enable vertical scrolling
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = NSColor.textBackgroundColor

        context.coordinator.textView = textView
        context.coordinator.fontSize = fontSize

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FocusableTextView else { return }

        // Update editable state
        textView.isEditable = isEditable

        // Update font size if changed
        let currentFontSize = context.coordinator.fontSize
        if currentFontSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
            context.coordinator.fontSize = fontSize
        }

        // Update text only if it changed externally
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges

            // Auto-scroll to bottom if enabled
            if autoScrollToBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        // Apply text styling with replacement highlights
        let currentText = textView.string
        let attrString = NSMutableAttributedString(string: currentText)
        let fullRange = NSRange(location: 0, length: attrString.length)
        attrString.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        attrString.addAttribute(.backgroundColor, value: NSColor.clear, range: fullRange)
        attrString.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: fullRange)

        // Apply replacement highlights (underline + tooltip)
        if showReplacementHighlights {
            applyReplacementHighlights(to: attrString)
        }

        textView.textStorage?.setAttributedString(attrString)
    }

    /// Apply underline and tooltip for text replacement matches
    private func applyReplacementHighlights(to attrString: NSMutableAttributedString) {
        let matches = TextReplacementService.shared.findMatches(in: attrString.string)

        for match in matches {
            guard match.range.location + match.range.length <= attrString.length else { continue }

            // Add dotted underline
            attrString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            attrString.addAttribute(.underlineColor, value: NSColor.systemOrange, range: match.range)

            // Add tooltip showing replacement
            let tooltipText = "\(match.originalText) → \(match.replacementText)"
            attrString.addAttribute(.toolTip, value: tooltipText, range: match.range)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScrollableTextView
        weak var textView: NSTextView?
        var fontSize: CGFloat = NSFont.systemFontSize

        init(_ parent: ScrollableTextView) {
            self.parent = parent
            self.fontSize = parent.fontSize
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

struct TTSFloatingView: View {
    var appState: AppState
    let onClose: () -> Void

    @State private var editableText: String = ""
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.appState = appState
        self.onClose = onClose
        self._editableText = State(initialValue: appState.ttsText)
    }

    // Shortcut helpers
    private var speakShortcut: CustomShortcut { shortcutManager.shortcut(for: .ttsSpeak) }
    private var stopShortcut: CustomShortcut { shortcutManager.shortcut(for: .ttsStop) }
    private var saveShortcut: CustomShortcut { shortcutManager.shortcut(for: .ttsSave) }
    private var closeShortcut: CustomShortcut { shortcutManager.shortcut(for: .ttsClose) }

    // Whether the text editor should be disabled (read-only but still scrollable)
    private var isEditorDisabled: Bool {
        switch appState.ttsState {
        case .speaking, .loading, .paused:
            return true
        default:
            return false
        }
    }

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

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                // Only show close button in floating mode (standard window has title bar close button)
                if isFloatingStyle {
                    Button(action: {
                        appState.stopTTS()
                        onClose()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("w", modifiers: .command)
                    .help("Close (⌘W)")
                }

                statusIcon
                Text(headerText)
                    .font(.headline)
                Spacer()

                // Provider selector
                TTSProviderSelector(appState: appState)
                    .disabled(appState.ttsState == .speaking || appState.ttsState == .loading)

                // Voice selector
                TTSVoiceSelector(appState: appState)
                    .disabled(appState.ttsState == .speaking || appState.ttsState == .loading)

                // Speed selector
                TTSSpeedSelector(appState: appState)
                    .disabled(appState.ttsState == .speaking || appState.ttsState == .loading)

                // Output selector
                TTSAudioOutputSelector(appState: appState)
                    .disabled(appState.ttsState == .speaking || appState.ttsState == .loading)
            }

            // Content area - always editable TextEditor
            contentArea

            // Action buttons
            actionButtons
        }
        .padding(16)
        .frame(minWidth: 820, idealWidth: 900, maxWidth: 1200)
        .background(panelBackground)
        .cornerRadius(panelCornerRadius)
        .onAppear {
            #if DEBUG
            print("TTSFloatingView: onAppear - setting editableText from ttsText, length: \(appState.ttsText.count)")
            #endif
            editableText = appState.ttsText
        }
        .onChange(of: appState.ttsText) { _, newValue in
            // Sync when appState.ttsText changes externally
            #if DEBUG
            print("TTSFloatingView: onChange(ttsText) - current editableText length: \(editableText.count), new value length: \(newValue.count)")
            #endif
            if editableText != newValue {
                #if DEBUG
                print("TTSFloatingView: Updating editableText to new value")
                #endif
                editableText = newValue
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if appState.ttsState == .speaking {
            // Animated waveform icon for speaking state (matches menu bar style)
            TTSPulsingWaveformIcon()
                .frame(width: 28, height: 22)
        } else {
            Image(systemName: statusIconName)
                .foregroundColor(statusIconColor)
                .font(.title2)
                .frame(width: 28, height: 22)
        }
    }

    private var statusIconName: String {
        switch appState.ttsState {
        case .idle: return "speaker.wave.2"
        case .speaking: return "waveform"  // Not used when speaking (TTSPulsingWaveformIcon is used)
        case .loading: return "arrow.down.circle"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusIconColor: Color {
        switch appState.ttsState {
        case .idle: return .accentColor
        case .speaking: return .blue  // Not used when speaking (TTSPulsingWaveformIcon is used)
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
        VStack(spacing: 8) {
            // Error banner (displayed above text area)
            if case .error(let message) = appState.ttsState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }

            // Custom scrollable text view with loading overlay
            ScrollableTextView(
                text: $editableText,
                isEditable: !isEditorDisabled,
                highlightRange: nil,
                enableHighlight: false,
                fontSize: CGFloat(appState.panelTextFontSize)
            )
            .cornerRadius(8)
            .overlay(textAreaBorder)
            .overlay(
                // Loading overlay (matches STT style)
                Group {
                    if case .loading = appState.ttsState {
                        TTSLoadingIndicator()
                    }
                }
            )
            .frame(minHeight: 200, maxHeight: 400)
            .opacity(isEditorDisabled ? 0.85 : 1.0)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Spacer()

            switch appState.ttsState {
            case .idle, .error:
                Button {
                    if !editableText.isEmpty {
                        // Update ttsText and speak directly (user explicitly clicked Speak)
                        appState.ttsText = editableText
                        appState.speakCurrentText()
                    }
                } label: {
                    ButtonLabelWithShortcut(title: "Speak", shortcut: "(\(speakShortcut.displayString))", icon: "speaker.wave.2.fill", isProminent: true)
                }
                .applyCustomShortcut(speakShortcut)
                .buttonStyle(.borderedProminent)
                .disabled(editableText.isEmpty || appState.isSavingAudio)

                Button {
                    // Update ttsText before saving
                    appState.ttsText = editableText
                    appState.synthesizeAndSaveTTSAudio(editableText)
                } label: {
                    HStack(spacing: 4) {
                        if appState.isSavingAudio {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.body)
                        }
                        Text("Save Audio")
                            .font(.body)
                        Text("(\(saveShortcut.displayString))")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .applyCustomShortcut(saveShortcut)
                .disabled(editableText.count < 5 || appState.isSavingAudio)

            case .speaking:
                Button {
                    appState.pauseResumeTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Pause", shortcut: "(\(speakShortcut.displayString))", icon: "pause.fill")
                }
                .applyCustomShortcut(speakShortcut)

                Button {
                    appState.stopTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Stop", shortcut: "(\(stopShortcut.displayString))", icon: "stop.fill", isProminent: true)
                }
                .applyCustomShortcut(stopShortcut)
                .buttonStyle(.borderedProminent)

            case .paused:
                Button {
                    appState.pauseResumeTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Resume", shortcut: "(\(speakShortcut.displayString))", icon: "play.fill", isProminent: true)
                }
                .applyCustomShortcut(speakShortcut)
                .buttonStyle(.borderedProminent)

                Button {
                    appState.stopTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Stop", shortcut: "(\(stopShortcut.displayString))", icon: "stop.fill")
                }
                .applyCustomShortcut(stopShortcut)

            case .loading:
                Button {
                    appState.stopTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Cancel", shortcut: "(\(stopShortcut.displayString))", icon: "xmark.circle")
                }
                .applyCustomShortcut(stopShortcut)
            }
        }
    }
}

/// Pulsing waveform icon for TTS speaking state (matches menu bar style)
struct TTSPulsingWaveformIcon: View {
    @State private var animationPhase: Double = 0.0

    var body: some View {
        Image(systemName: "waveform")
            .font(.title2)
            .foregroundColor(Color.blue.opacity(pulsingOpacity))
            .onAppear {
                startPulseAnimation()
            }
    }

    private var pulsingOpacity: Double {
        // Smooth pulsing between 0.5 and 1.0 (matches StatusBarManager style)
        0.5 + 0.5 * sin(animationPhase)
    }

    private func startPulseAnimation() {
        // Continuous pulse animation (~1.2 seconds per cycle, matches menu bar)
        withAnimation(
            .linear(duration: 1.2)
            .repeatForever(autoreverses: false)
        ) {
            animationPhase = .pi * 2
        }
    }
}

/// Animated loading indicator for TTS audio generation (overlay style, matches STT)
struct TTSLoadingIndicator: View {
    @State private var animationPhase: Double = 0

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4
    private let minHeight: CGFloat = 8
    private let maxHeight: CGFloat = 25

    var body: some View {
        VStack(spacing: 6) {
            // Animated waveform bars (blue color for loading)
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: barWidth, height: barHeight(for: index))
                }
            }
            .frame(height: maxHeight)

            Text("Generating audio...")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .onAppear {
            startAnimation()
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Create wave effect with phase offset for each bar
        let phaseOffset = Double(index) * 0.4
        let wave = sin(animationPhase + phaseOffset)
        let normalizedWave = (wave + 1) / 2  // Convert from -1...1 to 0...1
        return minHeight + (maxHeight - minHeight) * CGFloat(normalizedWave)
    }

    private func startAnimation() {
        // Continuous animation loop
        withAnimation(
            .linear(duration: 0.8)
            .repeatForever(autoreverses: false)
        ) {
            animationPhase = .pi * 2
        }
    }
}

/// Compact audio output device selector for TTS panel
struct TTSAudioOutputSelector: View {
    var appState: AppState
    @State private var availableDevices: [AudioOutputDevice] = []

    private var currentName: String {
        if appState.selectedAudioOutputDeviceUID.isEmpty {
            return "System Default"
        }
        if let device = availableDevices.first(where: { $0.uid == appState.selectedAudioOutputDeviceUID }) {
            return device.name
        }
        return "System Default"
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Output:")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize()
            outputMenu
        }
        .fixedSize()
        .onAppear {
            loadDevices()
        }
    }

    private var outputMenu: some View {
        Menu {
            ForEach(availableDevices) { device in
                Button(action: {
                    appState.selectedAudioOutputDeviceUID = device.uid
                }) {
                    HStack {
                        Text(device.name)
                        if appState.selectedAudioOutputDeviceUID == device.uid {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            if availableDevices.isEmpty {
                Text("No output devices detected")
                    .foregroundColor(.secondary)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
                Text(currentName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.2))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func loadDevices() {
        availableDevices = AudioOutputManager.shared.availableOutputDevices()

        // If selected device is not in the list, reset to system default
        if !appState.selectedAudioOutputDeviceUID.isEmpty &&
           !availableDevices.contains(where: { $0.uid == appState.selectedAudioOutputDeviceUID }) {
            appState.selectedAudioOutputDeviceUID = ""
        }
    }
}

/// Compact TTS provider selector for panel header
struct TTSProviderSelector: View {
    var appState: AppState

    private var availableProviders: [TTSProvider] {
        TTSProvider.allCases.filter { provider in
            !provider.requiresAPIKey || hasAPIKey(for: provider)
        }
    }

    private func hasAPIKey(for provider: TTSProvider) -> Bool {
        switch provider {
        case .openAI:
            return appState.apiKeyManager.hasAPIKey(for: .openAI)
        case .gemini:
            return appState.apiKeyManager.hasAPIKey(for: .gemini)
        case .elevenLabs:
            return appState.apiKeyManager.hasAPIKey(for: .elevenLabs)
        case .macOS:
            return true
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Provider:")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize()
            Menu {
                ForEach(availableProviders, id: \.rawValue) { provider in
                    Button(action: {
                        appState.selectedTTSProvider = provider
                    }) {
                        HStack {
                            Text(provider.rawValue)
                            if appState.selectedTTSProvider == provider {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(appState.selectedTTSProvider.rawValue)
                    .font(.caption2)
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

/// Compact TTS voice selector for panel header
struct TTSVoiceSelector: View {
    var appState: AppState
    @State private var availableVoices: [TTSVoice] = []

    private var currentVoiceName: String {
        if let voice = availableVoices.first(where: { $0.id == appState.selectedTTSVoice }) {
            return voice.name
        }
        return appState.selectedTTSVoice.isEmpty ? "Auto" : appState.selectedTTSVoice
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Voice:")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize()
            Menu {
                ForEach(availableVoices) { voice in
                    Button(action: {
                        appState.selectedTTSVoice = voice.id
                    }) {
                        HStack {
                            Text(voice.name)
                            if appState.selectedTTSVoice == voice.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(currentVoiceName)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .fixedSize()
        .onAppear {
            loadVoices()
        }
        .onChange(of: appState.selectedTTSProvider) { _, _ in
            loadVoices()
        }
    }

    private func loadVoices() {
        let service = TTSFactory.makeService(for: appState.selectedTTSProvider)
        availableVoices = service.availableVoices()

        // If current voice is not in the list, select the default or first voice
        if !availableVoices.contains(where: { $0.id == appState.selectedTTSVoice }) {
            if let defaultVoice = availableVoices.first(where: { $0.isDefault }) {
                appState.selectedTTSVoice = defaultVoice.id
            } else if let firstVoice = availableVoices.first {
                appState.selectedTTSVoice = firstVoice.id
            }
        }
    }
}

/// Compact TTS speed selector for panel header
struct TTSSpeedSelector: View {
    var appState: AppState

    private var speedOptions: [Double] {
        [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    }

    private var supportsSpeed: Bool {
        if appState.selectedTTSProvider == .openAI {
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            return model != "gpt-4o-mini-tts"
        }
        return true
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Speed:")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize()
            Menu {
                ForEach(speedOptions, id: \.self) { speed in
                    Button(action: {
                        appState.selectedTTSSpeed = speed
                    }) {
                        HStack {
                            Text(String(format: "%.2fx", speed))
                            if abs(appState.selectedTTSSpeed - speed) < 0.01 {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(supportsSpeed ? String(format: "%.1fx", appState.selectedTTSSpeed) : "N/A")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!supportsSpeed)
        }
        .fixedSize()
    }
}
