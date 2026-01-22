import SwiftUI
import Carbon.HIToolbox

/// Shared reference holder for panel text views (used for spell check triggering)
/// Since TTS and STT panels are mutually exclusive, only one text view is active at a time
class PanelTextViewHolder {
    static var shared = PanelTextViewHolder()
    weak var textView: FocusableTextView?

    private init() {}

    func triggerSpellCheck() {
        #if DEBUG
        print("PanelTextViewHolder.triggerSpellCheck called, textView = \(String(describing: textView))")
        #endif

        guard let textView = textView else {
            #if DEBUG
            print("PanelTextViewHolder: No text view reference")
            #endif
            return
        }

        #if DEBUG
        print("PanelTextViewHolder: textView.string = '\(textView.string.prefix(50))...'")
        print("PanelTextViewHolder: textView.window = \(String(describing: textView.window))")
        #endif

        // Make the text view first responder
        textView.window?.makeFirstResponder(textView)

        // Check spelling from beginning
        textView.checkSpellingFromBeginning()
    }
}

/// Brief toast notification for spell check result
class SpellCheckToast {
    static func showNoErrors(in window: NSWindow?) {
        #if DEBUG
        print("SpellCheckToast: window = \(String(describing: window))")
        #endif
        guard let window = window else {
            #if DEBUG
            print("SpellCheckToast: window is nil, cannot show toast")
            #endif
            return
        }

        // Create a small toast view
        let toast = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        toast.material = .hudWindow
        toast.blendingMode = .behindWindow
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 8

        let label = NSTextField(labelWithString: "✓ No spelling errors")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor
        label.alignment = .center
        label.frame = toast.bounds
        label.autoresizingMask = [.width, .height]
        toast.addSubview(label)

        // Position at bottom center of window
        let windowFrame = window.contentView?.bounds ?? window.frame
        toast.frame.origin.x = (windowFrame.width - toast.frame.width) / 2
        toast.frame.origin.y = 60  // Above the action buttons
        toast.alphaValue = 0

        window.contentView?.addSubview(toast)

        // Animate in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            toast.animator().alphaValue = 1
        }) {
            // Hold for a moment, then fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    toast.animator().alphaValue = 0
                }) {
                    toast.removeFromSuperview()
                }
            }
        }
    }
}

/// Custom NSTextView subclass for TTS input
class FocusableTextView: NSTextView {
    // Focus is handled by FloatingWindowManager via didBecomeKeyNotification

    override func didChangeText() {
        super.didChangeText()

        // Check if spelling panel is visible and if there are no more errors
        let spellingPanel = NSSpellChecker.shared.spellingPanel
        if spellingPanel.isVisible {
            let spellChecker = NSSpellChecker.shared
            let misspelledRange = spellChecker.checkSpelling(of: string, startingAt: 0)

            if misspelledRange.location == NSNotFound {
                // No more spelling errors - close the panel
                spellingPanel.orderOut(nil)

                #if DEBUG
                print("FocusableTextView: No more spelling errors, closed panel automatically")
                #endif
            }
        }
    }

    /// Check spelling from the beginning of the document and show the spelling panel
    func checkSpellingFromBeginning() {
        // Move cursor to beginning to ensure we check the entire document
        setSelectedRange(NSRange(location: 0, length: 0))

        // Use NSSpellChecker to find the first misspelled word
        let spellChecker = NSSpellChecker.shared
        let misspelledRange = spellChecker.checkSpelling(of: string, startingAt: 0)

        #if DEBUG
        print("SpellCheck: text length = \(string.count), misspelledRange = \(misspelledRange)")
        #endif

        if misspelledRange.location != NSNotFound {
            // Select the misspelled word
            setSelectedRange(misspelledRange)
            scrollRangeToVisible(misspelledRange)

            // Show the spelling panel
            showGuessPanel(nil)
        } else {
            #if DEBUG
            print("SpellCheck: No errors found, closing panel and showing toast")
            #endif

            // No spelling errors found - close the spelling panel if open
            let spellingPanel = NSSpellChecker.shared.spellingPanel
            spellingPanel.orderOut(nil)

            #if DEBUG
            print("SpellCheck: Spelling panel closed, isVisible = \(spellingPanel.isVisible)")
            #endif

            // Show a brief alert instead of toast (for better visibility)
            let alert = NSAlert()
            alert.messageText = "Spell Check Complete"
            alert.informativeText = "No spelling errors found."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            if let parentWindow = window {
                alert.beginSheetModal(for: parentWindow)
            } else {
                alert.runModal()
            }
        }
    }
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
    var isShowingTranslation: Bool = false  // Show different background for translated text

    /// Background color for translated text state
    private var translationBackgroundColor: NSColor {
        NSColor.systemBlue.withAlphaComponent(0.08)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = FocusableTextView()

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.backgroundColor = isShowingTranslation ? translationBackgroundColor : NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Enable spell checking
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true

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
        scrollView.backgroundColor = isShowingTranslation ? translationBackgroundColor : NSColor.textBackgroundColor

        context.coordinator.textView = textView
        context.coordinator.fontSize = fontSize

        // Register with shared holder for spell check access
        PanelTextViewHolder.shared.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FocusableTextView else { return }

        // Update editable state
        textView.isEditable = isEditable

        // Update background color for translation state
        let bgColor = isShowingTranslation ? translationBackgroundColor : NSColor.textBackgroundColor
        textView.backgroundColor = bgColor
        scrollView.backgroundColor = bgColor

        // Update font size if changed
        let currentFontSize = context.coordinator.fontSize
        if currentFontSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
            context.coordinator.fontSize = fontSize
        }

        // Update text only if it changed externally (not from user editing)
        // Check if the text view has focus - if so, don't overwrite user edits
        // Exceptions:
        // - Always allow clearing text (text.isEmpty)
        // - Always allow updates when not editable (e.g., during STT recording)
        let isFirstResponder = textView.window?.firstResponder === textView
        let textChanged = textView.string != text
        let shouldUpdate = textChanged && (!isFirstResponder || text.isEmpty || !isEditable)

        if shouldUpdate {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges

            // Auto-scroll to bottom if enabled
            if autoScrollToBottom {
                textView.scrollToEndOfDocument(nil)
            }

            // Apply text styling with replacement highlights only when text is externally set
            applyTextStyling(to: textView)
        }
    }

    /// Apply text styling with replacement highlights
    private func applyTextStyling(to textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }

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

        // Preserve selection
        let selectedRanges = textView.selectedRanges
        textStorage.setAttributedString(attrString)
        textView.selectedRanges = selectedRanges
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

    /// Trigger spell checking on the text view
    func triggerSpellCheck(coordinator: Coordinator) {
        guard let textView = coordinator.textView as? FocusableTextView else { return }

        // Make the text view first responder
        textView.window?.makeFirstResponder(textView)

        // Use the custom method to check from beginning
        textView.checkSpellingFromBeginning()
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
    private var fontSizeIncreaseShortcut: CustomShortcut { shortcutManager.shortcut(for: .fontSizeIncrease) }
    private var fontSizeDecreaseShortcut: CustomShortcut { shortcutManager.shortcut(for: .fontSizeDecrease) }
    private var fontSizeResetShortcut: CustomShortcut { shortcutManager.shortcut(for: .fontSizeReset) }

    // Whether the text editor should be disabled (read-only but still scrollable)
    private var isEditorDisabled: Bool {
        // Disable when speaking/loading/paused or showing translated text
        if appState.translationState.isTranslated {
            return true
        }
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

    /// Placeholder overlay when text area is empty
    @ViewBuilder
    private var placeholderOverlay: some View {
        if editableText.isEmpty && appState.ttsState != .loading {
            let ttsShortcut = appState.hotKeyService?.ttsKeyCombo.displayString ?? "⌃⌥T"
            let ocrShortcut = appState.hotKeyService?.ocrKeyCombo.displayString ?? "⌃⌥⇧O"

            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.6))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Type text here, or:")
                        .foregroundColor(.secondary)
                    Text("• Select text elsewhere and press \(ttsShortcut)")
                        .foregroundColor(.secondary.opacity(0.8))
                    Text("• Use OCR (\(ocrShortcut)) to capture screen text")
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .font(.callout)
            }
        }
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

                // Speed selector - NOT disabled during playback (supports real-time adjustment)
                TTSSpeedSelector(appState: appState)
                    .disabled(appState.ttsState == .loading)

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
        .frame(minWidth: 820, idealWidth: 900, maxWidth: .infinity)
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
                // Reset translation state when new text comes in
                if appState.translationState.isTranslated {
                    appState.translationState = .idle
                    appState.originalTextBeforeTranslation = ""
                }
                editableText = newValue
            }
        }
        .onChange(of: appState.translationState) { oldState, newState in
            // Handle translation state changes
            switch newState {
            case .translated(let translatedText):
                // Resign first responder to allow text update through ScrollableTextView
                NSApp.keyWindow?.makeFirstResponder(nil)
                // Show translated text
                editableText = translatedText
                #if DEBUG
                print("TTSFloatingView: Translation complete, editableText updated to length \(translatedText.count)")
                #endif
            case .idle:
                // When reverting to original, restore original text
                if oldState.isTranslated && !appState.originalTextBeforeTranslation.isEmpty {
                    // Resign first responder to allow text update
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    editableText = appState.originalTextBeforeTranslation
                    #if DEBUG
                    print("TTSFloatingView: Reverted to original text")
                    #endif
                }
            case .error(let message):
                #if DEBUG
                print("TTSFloatingView: Translation error: \(message)")
                #endif
            case .translating:
                break
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
                        .font(.callout)
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
                fontSize: CGFloat(appState.panelTextFontSize),
                isShowingTranslation: appState.translationState.isTranslated
            )
            .cornerRadius(8)
            .overlay(textAreaBorder)
            .overlay(placeholderOverlay)
            .overlay(
                // Loading overlay (matches STT style)
                Group {
                    if case .loading = appState.ttsState {
                        TTSLoadingIndicator()
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
            .frame(minHeight: 200, maxHeight: .infinity)
            .opacity(isEditorDisabled ? 0.85 : 1.0)
        }
    }

    /// Floating action buttons inside text area (Font size, Spell Check, Clear)
    @ViewBuilder
    private var textAreaFloatingButtons: some View {
        // Only show when not speaking/loading and text is not empty
        let isActive = appState.ttsState == .speaking || appState.ttsState == .loading
        if !isActive && !editableText.isEmpty {
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
                    editableText = ""
                    appState.ttsText = ""
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
        let isActive = appState.ttsState == .speaking || appState.ttsState == .loading
        if !isActive {
            TranslationControls(
                appState: appState,
                text: displayText,
                onTranslate: { translatedText in
                    editableText = translatedText
                }
            )
            .padding(8)
        }
    }

    /// Text to use for translation - always use original text, not translated text
    private var displayText: String {
        // When already translated, use the saved original for re-translation
        // This prevents originalTextBeforeTranslation from being corrupted
        if appState.translationState.isTranslated && !appState.originalTextBeforeTranslation.isEmpty {
            return appState.originalTextBeforeTranslation
        }
        return editableText
    }

    /// Show the macOS spelling panel and check spelling
    private func showSpellingPanel() {
        // Use the shared holder to trigger spell check on the TTS text view
        PanelTextViewHolder.shared.triggerSpellCheck()
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // OCR capture button
            Button(action: {
                appState.startOCR()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "text.viewfinder")
                        .font(.body)
                    Text("OCR")
                        .font(.callout)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Capture text with OCR (⌃⌥⇧O)")
            .disabled(appState.ttsState == .speaking || appState.ttsState == .loading)

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
                            .font(.callout)
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
                .font(.callout)
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
                .font(.callout)
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
                    .font(.callout)
                Text(currentName)
                    .font(.callout)
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

/// Compact TTS voice selector for panel header
struct TTSVoiceSelector: View {
    var appState: AppState
    @State private var availableVoices: [TTSVoice] = []

    /// Short voice name for display in header (name only, without description after hyphen)
    private var currentVoiceNameShort: String {
        if let voice = availableVoices.first(where: { $0.id == appState.selectedTTSVoice }) {
            // Extract just the name part before " - " if present
            if let hyphenRange = voice.name.range(of: " - ") {
                return String(voice.name[..<hyphenRange.lowerBound])
            }
            return voice.name
        }
        return appState.selectedTTSVoice.isEmpty ? "Auto" : appState.selectedTTSVoice
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Voice:")
                .font(.callout)
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
                Text(currentVoiceNameShort)
                    .font(.callout)
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

/// Compact TTS speed selector for panel header with popover slider
/// Supports real-time playback rate adjustment during speaking
struct TTSSpeedSelector: View {
    var appState: AppState
    @State private var showSpeedPopover = false

    /// Whether we're in a speaking or paused state (can adjust playback rate)
    private var isPlaying: Bool {
        appState.ttsState == .speaking || appState.ttsState == .paused
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Speed:")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize()

            // Clickable speed value that shows popover
            Button(action: {
                showSpeedPopover.toggle()
            }) {
                Text(String(format: "%.2fx", appState.selectedTTSSpeed))
                    .font(.callout)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSpeedPopover, arrowEdge: .bottom) {
                VStack(spacing: 8) {
                    Text("Playback Speed")
                        .font(.headline)

                    HStack(spacing: 8) {
                        Text("0.5x")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Slider(
                            value: Binding(
                                get: { appState.selectedTTSSpeed },
                                set: { newValue in
                                    appState.selectedTTSSpeed = newValue
                                    // During playback, update playback rate in real-time
                                    if isPlaying {
                                        appState.setTTSPlaybackRate(Float(newValue))
                                    }
                                }
                            ),
                            in: 0.5...2.0,
                            step: 0.05
                        )
                        .frame(width: 150)

                        Text("2.0x")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(String(format: "%.2fx", appState.selectedTTSSpeed))
                        .font(.title2)
                        .fontWeight(.semibold)
                        .monospacedDigit()

                    // Quick preset buttons
                    HStack(spacing: 8) {
                        ForEach([0.75, 1.0, 1.25, 1.5], id: \.self) { speed in
                            Button(String(format: "%.2fx", speed)) {
                                appState.selectedTTSSpeed = speed
                                if isPlaying {
                                    appState.setTTSPlaybackRate(Float(speed))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding()
                .frame(width: 280)
            }
        }
        .fixedSize()
        .help(isPlaying ? "Click to adjust playback speed" : "Click to set playback speed")
    }
}
