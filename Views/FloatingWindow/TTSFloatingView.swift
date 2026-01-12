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

    // Number of words to highlight before/after current word with gradient
    private let gradientRadius = 2

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = FocusableTextView()

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
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

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FocusableTextView else { return }

        // Update editable state
        textView.isEditable = isEditable

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
            attrString.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.systemFontSize), range: fullRange)

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

            textView.textStorage?.setAttributedString(attrString)
        } else if !enableHighlight || highlightRange == nil {
            // Reset to plain text when not highlighting
            let currentText = textView.string
            let attrString = NSMutableAttributedString(string: currentText)
            let fullRange = NSRange(location: 0, length: attrString.length)
            attrString.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
            attrString.addAttribute(.backgroundColor, value: NSColor.clear, range: fullRange)
            attrString.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.systemFontSize), range: fullRange)
            textView.textStorage?.setAttributedString(attrString)
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

        init(_ parent: ScrollableTextView) {
            self.parent = parent
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
                statusIcon
                Text(headerText)
                    .font(.headline)
                Spacer()

                // Provider badge
                HStack(spacing: 4) {
                    Text("Provider:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(appState.selectedTTSProvider.rawValue)
                        .font(.caption2)
                }
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
                .help("Close (\(closeShortcut.displayString))")
            }

            // Content area - always editable TextEditor
            contentArea

            // Action buttons
            actionButtons
        }
        .padding(16)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 800)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .onAppear {
            editableText = appState.ttsText
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
            // Custom scrollable text view that allows scrolling even when read-only
            ScrollableTextView(
                text: $editableText,
                isEditable: !isEditorDisabled,
                highlightRange: appState.currentSpeakingRange,
                enableHighlight: appState.enableWordHighlight && appState.ttsState == .speaking
            )
            .cornerRadius(8)
            .frame(minHeight: 200, maxHeight: 400)
            .opacity(isEditorDisabled ? 0.85 : 1.0)

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

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Spacer()

            switch appState.ttsState {
            case .idle, .error:
                Button {
                    if !editableText.isEmpty {
                        appState.startTTSWithText(editableText)
                    }
                } label: {
                    ButtonLabelWithShortcut(title: "Speak", shortcut: "(\(speakShortcut.displayString))")
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
                        ButtonLabelWithShortcut(title: "Save", shortcut: "(\(saveShortcut.displayString))")
                    }
                    .applyCustomShortcut(saveShortcut)
                    .disabled(!appState.canSaveTTSAudio(for: editableText))
                }

            case .speaking:
                Button {
                    appState.pauseResumeTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Pause", shortcut: "(\(speakShortcut.displayString))")
                }
                .applyCustomShortcut(speakShortcut)

                Button {
                    appState.stopTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Stop", shortcut: "(\(stopShortcut.displayString))")
                }
                .applyCustomShortcut(stopShortcut)
                .buttonStyle(.borderedProminent)

            case .paused:
                Button {
                    appState.pauseResumeTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Resume", shortcut: "(\(speakShortcut.displayString))")
                }
                .applyCustomShortcut(speakShortcut)
                .buttonStyle(.borderedProminent)

                Button {
                    appState.stopTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Stop", shortcut: "(\(stopShortcut.displayString))")
                }
                .applyCustomShortcut(stopShortcut)

            case .loading:
                Button {
                    appState.stopTTS()
                } label: {
                    ButtonLabelWithShortcut(title: "Cancel", shortcut: "(\(stopShortcut.displayString))")
                }
                .applyCustomShortcut(stopShortcut)
            }
        }
    }
}
