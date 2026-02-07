import SwiftUI

/// Subtitle overlay view for displaying real-time transcription
struct SubtitleOverlayView: View {
    @Environment(AppState.self) var appState
    @State private var showControls = false
    @State private var showLanguageMenu = false

    /// Height for each line of text (font size + line spacing)
    private var lineHeight: CGFloat {
        appState.subtitleFontSize * 1.4
    }

    /// Detect if text is primarily RTL (Arabic, Hebrew, etc.)
    /// Uses character counting to handle mixed LTR/RTL content
    private func isRTLText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        var rtlCount = 0
        var ltrCount = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            // RTL scripts: Arabic, Hebrew, Syriac, Thaana, etc.
            // Arabic: 0x0600-0x06FF, 0x0750-0x077F, 0x08A0-0x08FF, 0xFB50-0xFDFF, 0xFE70-0xFEFF
            // Hebrew: 0x0590-0x05FF, 0xFB1D-0xFB4F
            if (0x0590...0x05FF).contains(value) ||
               (0x0600...0x06FF).contains(value) ||
               (0x0750...0x077F).contains(value) ||
               (0x08A0...0x08FF).contains(value) ||
               (0xFB1D...0xFB4F).contains(value) ||
               (0xFB50...0xFDFF).contains(value) ||
               (0xFE70...0xFEFF).contains(value) {
                rtlCount += 1
            }
            // Basic Latin letters (A-Z, a-z) and extended Latin
            else if (0x0041...0x005A).contains(value) ||  // A-Z
                    (0x0061...0x007A).contains(value) ||  // a-z
                    (0x00C0...0x024F).contains(value) {   // Latin Extended
                ltrCount += 1
            }
            // CJK characters count as LTR for alignment purposes
            else if (0x4E00...0x9FFF).contains(value) ||  // CJK Unified
                    (0x3040...0x309F).contains(value) ||  // Hiragana
                    (0x30A0...0x30FF).contains(value) ||  // Katakana
                    (0xAC00...0xD7AF).contains(value) {   // Hangul
                ltrCount += 1
            }
        }

        // RTL if more than 50% of directional characters are RTL
        let total = rtlCount + ltrCount
        return total > 0 && rtlCount > total / 2
    }

    /// Maximum height for the text area based on max lines setting
    private var maxTextHeight: CGFloat {
        lineHeight * CGFloat(appState.subtitleMaxLines)
    }

    /// Text to display in the subtitle
    private var displayText: String {
        if appState.subtitleTranslationEnabled && !appState.subtitleTranslatedText.isEmpty {
            return appState.subtitleTranslatedText
        }
        return appState.subtitleText
    }

    /// Original text (for dual display mode)
    private var originalText: String {
        appState.subtitleText
    }

    var body: some View {
        ZStack {
            // Invisible hit area for dragging - fills entire window
            Color.white.opacity(0.001)

            VStack(spacing: 0) {
                subtitleContent
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var subtitleContent: some View {
        // Use subtitleText which only contains text from current recording session
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRTL = isRTLText(text)
        let textAlignment: TextAlignment = isRTL ? .trailing : .leading
        let frameAlignment: Alignment = isRTL ? .trailing : .leading

        // Always show the container when recording, even if text is empty
        if appState.isRecording || !text.isEmpty {
            VStack(alignment: isRTL ? .trailing : .leading, spacing: 8) {
                // Header with recording indicator and controls
                headerView

                // Original text (shown when dual display is enabled)
                if appState.subtitleShowOriginal && appState.subtitleTranslationEnabled && !original.isEmpty && text != original {
                    Text(original)
                        .font(.system(size: appState.subtitleFontSize * 0.7, weight: .regular))
                        .foregroundColor(.white.opacity(appState.subtitleOpacity * 0.6))
                        .multilineTextAlignment(textAlignment)
                        .frame(maxWidth: .infinity, alignment: frameAlignment)
                        .lineLimit(2)
                }

                // Scrollable transcription text area
                if !text.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(text)
                                .font(.system(size: appState.subtitleFontSize, weight: .medium))
                                .foregroundColor(.white.opacity(appState.subtitleOpacity))
                                .multilineTextAlignment(textAlignment)
                                .frame(maxWidth: .infinity, alignment: frameAlignment)
                                .id("subtitleText")
                        }
                        .frame(maxHeight: maxTextHeight)
                        .mask(
                            // Fade out at the top when scrolled
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.1),
                                    .init(color: .black, location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .onChange(of: text) { _, _ in
                            // Smooth scroll to bottom when text changes
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("subtitleText", anchor: .bottom)
                            }
                        }
                        .onAppear {
                            // Initial scroll to bottom
                            proxy.scrollTo("subtitleText", anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(appState.subtitleBackgroundOpacity))
            )
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            // Recording indicator with stop shortcut (left side)
            if appState.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))

                    // Translation in progress indicator (shown next to Recording)
                    if appState.subtitleTranslationEnabled && appState.subtitleTranslationState.isTranslating {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    }

                    // Show global hotkey to stop
                    if let shortcut = appState.hotKeyService?.sttKeyCombo.displayString {
                        Text("(\(shortcut) to stop)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }

            Spacer()

            // Inline controls (shown when expanded) - excludes translation toggle
            if showControls {
                inlineControls
            }

            // Translation toggle - always visible
            translationToggle

            // Toggle controls visibility button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
            } label: {
                Image(systemName: showControls ? "chevron.up" : "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(showControls ? "Hide controls" : "Show controls")

            // Reset position button (shown when using custom position)
            if appState.subtitleUseCustomPosition {
                Button {
                    SubtitleOverlayManager.shared.resetToPresetPosition()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Reset to default position")
            }
        }
        .frame(height: 20)
    }

    /// Translation toggle that's always visible in header
    @ViewBuilder
    private var translationToggle: some View {
        @Bindable var appState = appState

        HStack(spacing: 6) {
            // Translation toggle button
            Button {
                appState.subtitleTranslationEnabled.toggle()
            } label: {
                Image(systemName: appState.subtitleTranslationEnabled ? "globe.badge.chevron.backward" : "globe")
                    .font(.system(size: 11))
                    .foregroundColor(appState.subtitleTranslationEnabled ? .blue : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(appState.subtitleTranslationEnabled ? "Disable translation" : "Enable translation")

            // Provider and language selector (only when translation is enabled)
            if appState.subtitleTranslationEnabled {
                // Provider selector
                SubtitleProviderMenu(appState: appState)

                Text("→")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))

                // Language selector
                SubtitleLanguageMenu(appState: appState)
            }
        }
    }

    @ViewBuilder
    private var inlineControls: some View {
        @Bindable var appState = appState

        HStack(spacing: 14) {
            // Font size control
            HStack(spacing: 4) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))

                HStack(spacing: 3) {
                    Button {
                        if appState.subtitleFontSize > 18 {
                            appState.subtitleFontSize -= 2
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(appState.subtitleFontSize))")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 20)

                    Button {
                        if appState.subtitleFontSize < 48 {
                            appState.subtitleFontSize += 2
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Max lines control
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))

                HStack(spacing: 3) {
                    Button {
                        if appState.subtitleMaxLines > 2 {
                            appState.subtitleMaxLines -= 1
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Text("\(appState.subtitleMaxLines)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 12)

                    Button {
                        if appState.subtitleMaxLines < 6 {
                            appState.subtitleMaxLines += 1
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

/// Language menu that shows only available languages for macOS translation
struct SubtitleLanguageMenu: View {
    @Bindable var appState: AppState
    @State private var availableLanguages: [LanguageCode] = []
    @State private var isLoading = true

    var body: some View {
        Menu {
            if isLoading {
                Text("Loading...")
            } else if availableLanguages.isEmpty {
                Text("No languages available")
            } else {
                ForEach(availableLanguages) { language in
                    Button {
                        appState.subtitleTranslationLanguage = language
                    } label: {
                        HStack {
                            Text(language.displayName)
                            if language == appState.subtitleTranslationLanguage {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(appState.subtitleTranslationLanguage.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task {
            await loadAvailableLanguages()
        }
        .onChange(of: appState.subtitleTranslationProvider) { _, _ in
            Task {
                await loadAvailableLanguages()
            }
        }
    }

    private func loadAvailableLanguages() async {
        isLoading = true

        if appState.subtitleTranslationProvider == .macOS {
            // Only show installed languages for macOS
            availableLanguages = await MacOSTranslationAvailability.shared.getAvailableLanguages()

            // If current selection is not available, switch to first available
            if !availableLanguages.contains(appState.subtitleTranslationLanguage),
               let first = availableLanguages.first {
                appState.subtitleTranslationLanguage = first
            }
        } else {
            // LLM providers support all languages
            availableLanguages = LanguageCode.allCases.filter { $0 != .auto }
        }

        isLoading = false
    }
}

/// Provider menu for subtitle translation
struct SubtitleProviderMenu: View {
    @Bindable var appState: AppState

    /// Available providers (with API keys and OS support)
    private var availableProviders: [TranslationProvider] {
        TranslationProvider.allCases.filter { provider in
            // macOS provider requires macOS 26+ for contextual translation
            if provider == .macOS {
                #if compiler(>=6.1)
                if #available(macOS 26.0, *) {
                    return true
                }
                #endif
                return false
            }
            return provider.isAvailable || hasAPIKey(for: provider)
        }
    }

    /// Check if API key is available for a provider
    private func hasAPIKey(for provider: TranslationProvider) -> Bool {
        guard let envKey = provider.envKeyName else { return true }
        return APIKeyManager.shared.getAPIKey(for: envKey) != nil
    }

    var body: some View {
        Menu {
            ForEach(availableProviders) { provider in
                Button {
                    appState.subtitleTranslationProvider = provider
                } label: {
                    HStack {
                        Text(provider.displayName)
                        if provider == appState.subtitleTranslationProvider {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!hasAPIKey(for: provider) && provider.requiresAPIKey)
            }
        } label: {
            Text(appState.subtitleTranslationProvider.displayName)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Translation provider")
    }
}
