import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) var appState
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 10) {
            // App title and status
            HStack {
                Image(systemName: appState.isRecording ? "mic.fill" : "waveform.badge.microphone")
                    .foregroundColor(appState.isRecording ? .red : .accentColor)
                    .font(.title2)

                Text("TypeTalk")
                    .font(.headline)

                Spacer()

                // Status indicator
                if appState.isRecording {
                    Text("Recording")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .cornerRadius(4)
                } else if appState.ttsState == .speaking {
                    Text("Speaking")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .cornerRadius(4)
                } else if appState.isProcessing || appState.ttsState == .loading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }

            Divider()
                .padding(.vertical, 2)

            // MARK: - STT Section
            Text("Speech-to-Text")
                .font(.caption)
                .foregroundColor(.secondary)

            // STT Action button with shortcut
            Button(action: {
                appState.toggleRecording()
            }) {
                HStack {
                    Image(systemName: appState.isRecording ? "stop.fill" : "record.circle")
                        .foregroundColor(appState.isRecording ? .red : .primary)
                        .frame(width: 20)
                    Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.sttKeyCombo.displayString ?? "⌘⇧Space")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.isProcessing)

            // STT Provider picker (compact)
            HStack {
                Text("Provider:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $appState.selectedRealtimeProvider) {
                    ForEach(availableSTTProviders) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .scaleEffect(0.9, anchor: .leading)
            }

            Divider()
                .padding(.vertical, 2)

            // MARK: - TTS Section
            Text("Text-to-Speech")
                .font(.caption)
                .foregroundColor(.secondary)

            // TTS Action button with shortcut
            Button(action: {
                NSApp.keyWindow?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    appState.startTTS()
                }
            }) {
                HStack {
                    Image(systemName: "speaker.wave.2")
                        .frame(width: 20)
                    Text("Read Selected Text")
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.ttsKeyCombo.displayString ?? "⌃⌥T")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.ttsState == .speaking || appState.ttsState == .loading)

            // TTS Provider picker (compact)
            HStack {
                Text("Provider:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $appState.selectedTTSProvider) {
                    ForEach(availableTTSProviders) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .scaleEffect(0.9, anchor: .leading)
            }

            // TTS Speed slider (compact)
            HStack(spacing: 4) {
                Text("Speed:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 45, alignment: .leading)
                Slider(
                    value: $appState.selectedTTSSpeed,
                    in: ttsSpeedRange,
                    step: 0.1
                )
                .frame(maxWidth: 100)
                .disabled(!ttsSupportsSpeed)
                Text(ttsSupportsSpeed ? String(format: "%.1fx", appState.selectedTTSSpeed) : "N/A")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }
            .scaleEffect(0.9, anchor: .leading)
            .help(ttsSpeedHelpText)

            Divider()
                .padding(.vertical, 2)

            // MARK: - Footer Actions
            VStack(spacing: 6) {
                // Help - links to GitHub docs
                Button(action: {
                    openHelp()
                }) {
                    HStack {
                        Image(systemName: "questionmark.circle")
                            .frame(width: 20)
                        Text("Help & Documentation")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // About
                Button(action: {
                    openAbout()
                }) {
                    HStack {
                        Image(systemName: "info.circle")
                            .frame(width: 20)
                        Text("About TypeTalk")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Settings
                Button(action: {
                    openSettings()
                }) {
                    HStack {
                        Image(systemName: "gear")
                            .frame(width: 20)
                        Text("Settings...")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.vertical, 4)

                // Quit
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack {
                        Image(systemName: "power")
                            .frame(width: 20)
                        Text("Quit TypeTalk")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(width: 300)
    }

    // Get speed range for current TTS provider
    private var ttsSpeedRange: ClosedRange<Double> {
        // Use standard range for UI
        0.5...2.0
    }

    // Available STT providers (only those with API keys or not requiring them)
    private var availableSTTProviders: [RealtimeSTTProvider] {
        RealtimeSTTProvider.allCases.filter { provider in
            !provider.requiresAPIKey || hasSTTAPIKey(for: provider)
        }
    }

    // Available TTS providers (only those with API keys or not requiring them)
    private var availableTTSProviders: [TTSProvider] {
        TTSProvider.allCases.filter { provider in
            !provider.requiresAPIKey || hasTTSAPIKey(for: provider)
        }
    }

    private func hasSTTAPIKey(for provider: RealtimeSTTProvider) -> Bool {
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

    private func hasTTSAPIKey(for provider: TTSProvider) -> Bool {
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

    // Check if current provider/model supports speed control
    private var ttsSupportsSpeed: Bool {
        if appState.selectedTTSProvider == .openAI {
            // gpt-4o-mini-tts (default when empty) doesn't support speed
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            return model != "gpt-4o-mini-tts"
        }
        return true
    }

    // Help text for speed slider tooltip
    private var ttsSpeedHelpText: String {
        switch appState.selectedTTSProvider {
        case .openAI:
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            if model == "gpt-4o-mini-tts" {
                return "GPT-4o Mini TTSは速度制御非対応です。TTS-1またはTTS-1 HDを選択してください。"
            }
            return "再生速度を調整 (0.25x〜4.0x)"
        case .gemini:
            return "Geminiはプロンプトでペースを制御します（おおよその調整）"
        case .elevenLabs:
            return "再生速度を調整 (実際の範囲: 0.7x〜1.2x)"
        case .macOS:
            return "再生速度を調整"
        }
    }

    // Shortcut badge view
    private func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(4)
    }

    // Open About window
    private func openAbout() {
        // Close the menu bar popover first
        NSApp.keyWindow?.close()

        // Activate the app to bring it to front
        NSApp.activate(ignoringOtherApps: true)

        // Open the About window
        openWindow(id: "about")
    }

    // Open help documentation (GitHub)
    private func openHelp() {
        // Close the menu bar popover first
        NSApp.keyWindow?.close()

        // TODO: Replace with actual GitHub repository URL
        if let url = URL(string: "https://github.com/yohasebe/TypeTalk") {
            NSWorkspace.shared.open(url)
        }
    }

    // Open settings and bring window to front
    private func openSettings() {
        // Close the menu bar popover first
        NSApp.keyWindow?.close()

        // Activate the app to bring it to front
        NSApp.activate(ignoringOtherApps: true)

        // Use the environment action to open settings (must be called synchronously)
        openSettingsAction()

        // Ensure the settings window is brought to front after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for window in NSApp.windows {
                if window.title == "Settings" || window.identifier?.rawValue.contains("Settings") == true {
                    window.level = .floating
                    window.makeKeyAndOrderFront(nil)
                    // Reset to normal level after bringing to front
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        window.level = .normal
                    }
                    break
                }
            }
        }
    }
}
