import SwiftUI

/// Subtitle overlay view for displaying real-time transcription
struct SubtitleOverlayView: View {
    @Environment(AppState.self) var appState
    @State private var showControls = false

    /// Height for each line of text (font size + line spacing)
    private var lineHeight: CGFloat {
        appState.subtitleFontSize * 1.4
    }

    /// Maximum height for the text area based on max lines setting
    private var maxTextHeight: CGFloat {
        lineHeight * CGFloat(appState.subtitleMaxLines)
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
        let text = appState.currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)

        // Always show the container when recording, even if text is empty
        if appState.isRecording || !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Header with recording indicator and controls
                headerView

                // Scrollable transcription text area
                if !text.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(text)
                                .font(.system(size: appState.subtitleFontSize, weight: .medium))
                                .foregroundColor(.white.opacity(appState.subtitleOpacity))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(appState.subtitleBackgroundOpacity))
            )
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            // Recording indicator (left side)
            if appState.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            Spacer()

            // Inline controls (shown when expanded)
            if showControls {
                inlineControls
            }

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

    @ViewBuilder
    private var inlineControls: some View {
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
