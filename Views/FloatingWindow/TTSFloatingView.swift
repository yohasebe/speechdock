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
    var highlightRange: NSRange?
    var enableHighlight: Bool
    var showReplacementHighlights: Bool = true
    var fontSize: CGFloat = NSFont.systemFontSize

    // Number of words to highlight before/after current word with gradient
    private let gradientRadius = 2

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
        }

        // Apply word highlighting with gradient
        if enableHighlight, let currentRange = highlightRange, currentRange.location != NSNotFound {
            let attrString = NSMutableAttributedString(string: textView.string)
            let fullRange = NSRange(location: 0, length: attrString.length)

            // Reset all attributes
            attrString.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
            attrString.addAttribute(.backgroundColor, value: NSColor.clear, range: fullRange)
            attrString.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: fullRange)

            // Calculate all word ranges (including trailing punctuation) and find current word index
            let wordRanges = calculateWordRangesWithPunctuation(for: textView.string)
            if let currentIndex = findWordIndex(for: currentRange, in: wordRanges) {
                // Apply gradient highlighting
                for offset in -gradientRadius...gradientRadius {
                    let wordIndex = currentIndex + offset
                    guard wordIndex >= 0 && wordIndex < wordRanges.count else { continue }

                    let wordRange = wordRanges[wordIndex]
                    guard wordRange.location + wordRange.length <= attrString.length else { continue }

                    let distance = abs(offset)
                    let alpha: CGFloat

                    switch distance {
                    case 0:  // Current word - full highlight
                        alpha = 0.45
                    case 1:  // Adjacent words - medium highlight
                        alpha = 0.25
                    case 2:  // 2 words away - light highlight
                        alpha = 0.12
                    default:
                        alpha = 0.0
                    }

                    if alpha > 0 {
                        attrString.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(alpha), range: wordRange)
                    }
                }
            }

            // Apply replacement highlights on top of word highlights
            if showReplacementHighlights {
                applyReplacementHighlights(to: attrString)
            }

            textView.textStorage?.setAttributedString(attrString)
        } else if !enableHighlight || highlightRange == nil {
            // Reset to plain text when not highlighting
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

    /// Calculate word ranges including trailing punctuation
    private func calculateWordRangesWithPunctuation(for text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let nsString = text as NSString

        let tokenizer = CFStringTokenizerCreate(
            nil,
            text as CFString,
            CFRangeMake(0, text.count),
            kCFStringTokenizerUnitWord,
            CFLocaleCopyCurrent()
        )

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            var wordRange = NSRange(location: cfRange.location, length: cfRange.length)

            // Extend range to include trailing punctuation (but not spaces)
            var endLocation = wordRange.location + wordRange.length
            while endLocation < nsString.length {
                let char = nsString.character(at: endLocation)
                let scalar = Unicode.Scalar(char)
                // Include punctuation but stop at whitespace
                if let s = scalar, CharacterSet.punctuationCharacters.contains(s) {
                    endLocation += 1
                } else {
                    break
                }
            }
            wordRange.length = endLocation - wordRange.location

            ranges.append(wordRange)
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        return ranges
    }

    /// Calculate word ranges using CFStringTokenizer (for matching)
    private func calculateWordRanges(for text: String) -> [NSRange] {
        var ranges: [NSRange] = []

        let tokenizer = CFStringTokenizerCreate(
            nil,
            text as CFString,
            CFRangeMake(0, text.count),
            kCFStringTokenizerUnitWord,
            CFLocaleCopyCurrent()
        )

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            ranges.append(NSRange(location: cfRange.location, length: cfRange.length))
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        return ranges
    }

    /// Find the index of the word that matches the given range
    private func findWordIndex(for range: NSRange, in wordRanges: [NSRange]) -> Int? {
        // Find exact match or closest match
        for (index, wordRange) in wordRanges.enumerated() {
            if wordRange.location == range.location && wordRange.length == range.length {
                return index
            }
        }
        // Fallback: find the word that contains the range start
        for (index, wordRange) in wordRanges.enumerated() {
            if range.location >= wordRange.location &&
               range.location < wordRange.location + wordRange.length {
                return index
            }
        }
        return nil
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

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
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

                statusIcon
                Text(headerText)
                    .font(.headline)
                Spacer()

                // Provider badge
                infoBadge(label: "Provider", value: appState.selectedTTSProvider.rawValue)

                // Voice badge
                infoBadge(label: "Voice", value: currentVoiceName)

                // Speed badge
                infoBadge(label: "Speed", value: String(format: "%.1fx", appState.selectedTTSSpeed))
            }

            // Content area - always editable TextEditor
            contentArea

            // Action buttons
            actionButtons
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 800, maxWidth: 1000)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
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

    /// Get the display name for the current voice
    private var currentVoiceName: String {
        let service = TTSFactory.makeService(for: appState.selectedTTSProvider)
        let voices = service.availableVoices()
        if let voice = voices.first(where: { $0.id == appState.selectedTTSVoice }) {
            return voice.name
        }
        return appState.selectedTTSVoice.isEmpty ? "Auto" : appState.selectedTTSVoice
    }

    /// Info badge view for displaying provider, voice, speed
    private func infoBadge(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.2))
        .cornerRadius(4)
    }

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            // Custom scrollable text view that allows scrolling even when read-only
            ScrollableTextView(
                text: $editableText,
                isEditable: !isEditorDisabled,
                highlightRange: appState.currentSpeakingRange,
                enableHighlight: appState.enableWordHighlight && appState.ttsState == .speaking,
                fontSize: CGFloat(appState.panelTextFontSize)
            )
            .cornerRadius(8)
            .frame(minHeight: 200, maxHeight: 400)
            .opacity(isEditorDisabled ? 0.85 : 1.0)

            // Loading overlay with animated waveform
            if case .loading = appState.ttsState {
                TTSLoadingIndicator()
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

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Audio output selector on the left (disabled during playback)
            TTSAudioOutputSelector(appState: appState)
                .disabled(appState.ttsState == .speaking || appState.ttsState == .loading)

            Spacer()

            switch appState.ttsState {
            case .idle, .error:
                Button {
                    if !editableText.isEmpty {
                        appState.startTTSWithText(editableText)
                    }
                } label: {
                    ButtonLabelWithShortcut(title: "Speak", shortcut: "(\(speakShortcut.displayString))", icon: "speaker.wave.2.fill", isProminent: true)
                }
                .applyCustomShortcut(speakShortcut)
                .buttonStyle(.borderedProminent)
                .disabled(editableText.isEmpty || appState.isSavingAudio)

                if appState.isSavingAudio {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 60)
                } else {
                    Button {
                        appState.synthesizeAndSaveTTSAudio(editableText)
                    } label: {
                        ButtonLabelWithShortcut(title: "Save Audio", shortcut: "(\(saveShortcut.displayString))", icon: "square.and.arrow.down")
                    }
                    .applyCustomShortcut(saveShortcut)
                    .disabled(editableText.count < 5 || appState.isSavingAudio)
                }

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

/// Animated loading indicator for TTS audio generation
struct TTSLoadingIndicator: View {
    @State private var animationPhase: Double = 0

    private let barCount = 5
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let minHeight: CGFloat = 8
    private let maxHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 8) {
            // Animated waveform bars
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: barWidth, height: barHeight(for: index))
                }
            }
            .frame(height: maxHeight)

            Text("Generating audio...")
                .font(.caption)
                .foregroundColor(.secondary)

            ProgressView()
                .scaleEffect(0.8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(.windowBackgroundColor).opacity(0.95))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
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
            outputMenu
        }
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
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
