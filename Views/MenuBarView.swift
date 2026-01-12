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
                } else if appState.transcriptionState == .processing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Processing")
                            .font(.caption)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
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

            // Microphone permission warning
            if !appState.hasMicrophonePermission {
                permissionWarning(
                    icon: "mic.slash",
                    text: "Microphone access required",
                    action: openMicrophoneSettings
                )
            }

            // STT Action button with shortcut
            Button(action: {
                appState.toggleRecording()
            }) {
                HStack {
                    Image(systemName: appState.isRecording ? "stop.fill" : "record.circle")
                        .foregroundColor(appState.isRecording ? .red : (appState.hasMicrophonePermission ? .primary : .secondary))
                        .frame(width: 20)
                    Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                        .foregroundColor(appState.hasMicrophonePermission ? .primary : .secondary)
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.sttKeyCombo.displayString ?? "⌘⇧Space")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.isProcessing || !appState.hasMicrophonePermission)

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
            .disabled(!appState.hasMicrophonePermission)

            // Audio Input Source display
            HStack {
                Text("Input:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: appState.selectedAudioInputSourceType.icon)
                        .font(.caption)
                    Text(audioInputDisplayName)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(audioInputBackgroundColor)
                .cornerRadius(4)
                Spacer()
            }
            .disabled(!appState.hasMicrophonePermission)

            Divider()
                .padding(.vertical, 2)

            // MARK: - TTS Section
            Text("Text-to-Speech")
                .font(.caption)
                .foregroundColor(.secondary)

            // Accessibility permission warning
            if !appState.hasAccessibilityPermission {
                permissionWarning(
                    icon: "hand.raised.slash",
                    text: "Accessibility access required",
                    action: openAccessibilitySettings
                )
            }

            // TTS Action button with shortcut
            Button(action: {
                NSApp.keyWindow?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    appState.startTTS()
                }
            }) {
                HStack {
                    Image(systemName: "speaker.wave.2")
                        .foregroundColor(appState.hasAccessibilityPermission ? .primary : .secondary)
                        .frame(width: 20)
                    Text("Read Selected Text")
                        .foregroundColor(appState.hasAccessibilityPermission ? .primary : .secondary)
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.ttsKeyCombo.displayString ?? "⌃⌥T")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.ttsState == .speaking || appState.ttsState == .loading || !appState.hasAccessibilityPermission)

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
        .onAppear {
            // Update permission status each time menu appears
            appState.updatePermissionStatus()
        }
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
                return "GPT-4o Mini TTS does not support speed control. Select TTS-1 or TTS-1 HD."
            }
            return "Adjust playback speed (0.25x–4.0x)"
        case .gemini:
            return "Gemini uses prompt-based pacing (approximate adjustment)"
        case .elevenLabs:
            return "Adjust playback speed (actual range: 0.7x–1.2x)"
        case .macOS:
            return "Adjust playback speed"
        }
    }

    // Audio input source display name
    private var audioInputDisplayName: String {
        switch appState.selectedAudioInputSourceType {
        case .microphone:
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        case .applicationAudio:
            let appName = appState.systemAudioCaptureService.availableApps
                .first { $0.bundleID == appState.selectedAudioAppBundleID }?.name
            return appName ?? "App"
        }
    }

    // Audio input source background color
    private var audioInputBackgroundColor: Color {
        switch appState.selectedAudioInputSourceType {
        case .microphone:
            return Color.blue.opacity(0.2)
        case .systemAudio:
            return Color.green.opacity(0.2)
        case .applicationAudio:
            return Color.orange.opacity(0.2)
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

    // Permission warning view
    private func permissionWarning(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(text)
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // Open Microphone settings
    private func openMicrophoneSettings() {
        NSApp.keyWindow?.close()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // Open Accessibility settings
    private func openAccessibilitySettings() {
        NSApp.keyWindow?.close()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // Open About window
    private func openAbout() {
        // Close the menu bar popover first
        NSApp.keyWindow?.close()

        // Show in Dock while About window is open
        NSApp.setActivationPolicy(.regular)

        // Activate the app to bring it to front
        NSApp.activate(ignoringOtherApps: true)

        // Open the About window
        openWindow(id: "about")

        // Set up observer to hide from Dock when About window closes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for window in NSApp.windows {
                if window.identifier?.rawValue == "about" {
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification,
                        object: window,
                        queue: .main
                    ) { _ in
                        // Hide from Dock when About closes (only if Settings is not open)
                        let settingsOpen = NSApp.windows.contains { $0.title == "Settings" && $0.isVisible }
                        if !settingsOpen {
                            NSApp.setActivationPolicy(.accessory)
                        }
                    }
                    break
                }
            }
        }
    }

    // Open help documentation (GitHub)
    private func openHelp() {
        // Close the menu bar popover first
        NSApp.keyWindow?.close()

        if let url = URL(string: "https://github.com/yohasebe/typetalk") {
            NSWorkspace.shared.open(url)
        }
    }

    // Open settings and bring window to front
    private func openSettings() {
        // Close the menu bar popover first
        NSApp.keyWindow?.close()

        // Show in Dock while settings is open
        NSApp.setActivationPolicy(.regular)

        // Activate the app to bring it to front
        NSApp.activate(ignoringOtherApps: true)

        // Use the environment action to open settings (must be called synchronously)
        openSettingsAction()

        // Ensure the settings window is brought to front after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for window in NSApp.windows {
                if window.title == "Settings" || window.identifier?.rawValue.contains("Settings") == true {
                    window.makeKeyAndOrderFront(nil)

                    // Set up observer to hide from Dock when settings window closes
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification,
                        object: window,
                        queue: .main
                    ) { _ in
                        // Hide from Dock when settings closes (only if About is not open)
                        let aboutOpen = NSApp.windows.contains { $0.identifier?.rawValue == "about" && $0.isVisible }
                        if !aboutOpen {
                            NSApp.setActivationPolicy(.accessory)
                        }
                    }
                    break
                }
            }
        }
    }
}
