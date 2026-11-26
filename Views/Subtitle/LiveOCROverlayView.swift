import SwiftUI

/// Subtitle overlay while Live OCR runs: a compact control bar plus, when
/// enabled, the line being read (its translation when translating).
///
/// Only the bar and the text box draw anything. The rest of the window stays
/// fully transparent, so clicks there reach the video player underneath.
struct LiveOCROverlayView: View {
    @Environment(AppState.self) var appState

    private var isTopPosition: Bool {
        !appState.subtitleUseCustomPosition && appState.subtitlePosition == .top
    }

    /// The line now on screen, replaced by its translation once that arrives.
    private var spokenText: String {
        if appState.usesLiveOCRInterpreter, !appState.liveOCRInterpretedText.isEmpty {
            return appState.liveOCRInterpretedText
        }
        if appState.subtitleTranslationEnabled, !appState.subtitleTranslatedText.isEmpty,
           appState.isCurrentLiveOCRTranslation {
            return appState.subtitleTranslatedText
        }
        return appState.liveOCRText
    }

    private var isTranslating: Bool {
        appState.usesLiveOCRInterpreter || appState.subtitleTranslationEnabled
    }

    var body: some View {
        VStack(spacing: 8) {
            if isTopPosition {
                controlBar
                errorLine
                subtitleBox
            } else {
                subtitleBox
                controlBar
                errorLine
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isTopPosition ? .top : .bottom)
        .animation(.easeOut(duration: 0.15), value: appState.liveOCRShowText)
    }

    // MARK: - Subtitle text

    @ViewBuilder
    private var subtitleBox: some View {
        let text = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = appState.liveOCRText
        if appState.liveOCRShowText, !text.isEmpty {
            VStack(spacing: 4) {
                if appState.subtitleShowOriginal, isTranslating, original != text, !original.isEmpty {
                    Text(original)
                        .font(.system(size: appState.subtitleFontSize * 0.65, weight: .regular))
                        .foregroundColor(.white.opacity(appState.subtitleOpacity * 0.65))
                }
                Text(text)
                    .font(.system(size: appState.subtitleFontSize, weight: .semibold))
                    .foregroundColor(.white.opacity(appState.subtitleOpacity))
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }
            .multilineTextAlignment(.center)
            .lineLimit(appState.subtitleMaxLines)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(appState.subtitleBackgroundOpacity))
            )
            .transition(.opacity)
            .id(text)  // Cross-fade between lines instead of reflowing in place.
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            WindowDragHandle(color: .white.withAlphaComponent(0.45))
                .frame(width: 12, height: 18)

            statusIndicator

            divider

            voiceMenu

            if isTranslating {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                SubtitleLanguageMenu(appState: appState)
            }

            divider

            if !appState.usesLiveOCRInterpreter {
                barButton(
                    icon: appState.subtitleTranslationEnabled ? "globe.badge.chevron.backward" : "globe",
                    isOn: appState.subtitleTranslationEnabled,
                    help: appState.subtitleTranslationEnabled ? "Stop translating" : "Translate before speaking"
                ) { appState.subtitleTranslationEnabled.toggle() }
            }
            barButton(
                icon: appState.liveOCRShowText ? "captions.bubble.fill" : "captions.bubble",
                isOn: appState.liveOCRShowText,
                help: appState.liveOCRShowText ? "Hide subtitle text" : "Show subtitle text"
            ) { appState.liveOCRShowText.toggle() }
            barButton(
                icon: appState.liveOCRSpeakEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                isOn: appState.liveOCRSpeakEnabled,
                help: appState.liveOCRSpeakEnabled ? "Stop reading aloud" : "Read aloud"
            ) { appState.liveOCRSpeakEnabled.toggle() }

            Button { appState.stopLiveOCR() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Stop Live OCR")
            .accessibilityLabel("Stop Live OCR")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(max(0.55, appState.subtitleBackgroundOpacity))))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .fixedSize()
    }

    private var statusIndicator: some View {
        let speaking = appState.liveOCRIsSpeaking
        let color: Color = !appState.liveOCRSpeakEnabled ? .gray : (speaking ? .green : .orange)
        return HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundColor(color)
                .symbolEffect(.pulse, options: .repeating, isActive: speaking)
            Text(speaking ? LocalizedStringKey("Speaking") : LocalizedStringKey("Live OCR"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .frame(minWidth: 58, alignment: .leading)
            if appState.subtitleTranslationEnabled && appState.subtitleTranslationState.isTranslating
                && !appState.usesLiveOCRInterpreter {
                ProgressView().controlSize(.mini)
            }
        }
        .help(speaking ? Text("Reading the current line") : Text("Watching the selected region"))
    }

    private var voiceMenu: some View {
        Menu {
            ForEach(LiveOCRVoice.allCases) { voice in
                Button {
                    appState.liveOCRVoice = voice
                } label: {
                    if voice == appState.liveOCRVoice {
                        Label(voiceName(voice), systemImage: "checkmark")
                    } else {
                        Text(voiceName(voice))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.liveOCRVoice == .geminiLive ? "waveform.badge.mic" : "waveform")
                Text(voiceName(appState.liveOCRVoice))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Voice")
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = appState.liveOCRSpeechError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 480)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .help(error)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 14)
    }

    private func barButton(icon: String, isOn: Bool, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isOn ? .accentColor : .white.opacity(0.5))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }

    private func voiceName(_ voice: LiveOCRVoice) -> String {
        switch voice {
        case .textToSpeech:
            return String(format: NSLocalizedString("%@ TTS", comment: "Live OCR voice: the Text-to-Speech provider"),
                          appState.selectedTTSProvider.rawValue)
        case .macOS: return NSLocalizedString("macOS voice", comment: "Live OCR voice")
        case .geminiLive: return NSLocalizedString("Gemini Live", comment: "Live OCR voice")
        }
    }
}
