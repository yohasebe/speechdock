import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) var appState

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
            .buttonStyle(MenuBarActionButtonStyle())
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
            .disabled(!appState.hasMicrophonePermission || appState.isRecording)

            // Audio Input Source selector
            HStack {
                Text("Input:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                MenuBarAudioInputSelector(appState: appState)
                Spacer()
            }
            .disabled(!appState.hasMicrophonePermission || appState.isRecording)

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
            .buttonStyle(MenuBarActionButtonStyle())
            .disabled(appState.ttsState == .speaking || appState.ttsState == .loading || !appState.hasAccessibilityPermission)

            // OCR to TTS Action button with shortcut
            Button(action: {
                NSApp.keyWindow?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    appState.startOCR()
                }
            }) {
                HStack {
                    Image(systemName: "text.viewfinder")
                        .frame(width: 20)
                    Text("OCR Region to TTS")
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.ocrKeyCombo.displayString ?? "⌃⌥⇧O")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())
            .disabled(appState.ocrCoordinator.isSelecting || appState.ocrCoordinator.isProcessing)

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
            .disabled(isTTSActive)

            // TTS Model picker (compact)
            MenuBarTTSModelPicker(appState: appState)
                .disabled(isTTSActive)

            // TTS Voice picker (compact)
            MenuBarTTSVoicePicker(appState: appState)
                .disabled(isTTSActive)

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
            .disabled(isTTSActive)

            // Audio Output Device selector
            HStack {
                Text("Output:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                MenuBarAudioOutputSelector(appState: appState)
                Spacer()
            }
            .disabled(isTTSActive)

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

                // Check for Updates
                CheckForUpdatesView()
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

    // Check if TTS is currently active (speaking or loading)
    private var isTTSActive: Bool {
        appState.ttsState == .speaking || appState.ttsState == .loading
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
        case .macOS, .localWhisper:
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
        StatusBarManager.shared.closePopover()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // Open Accessibility settings
    private func openAccessibilitySettings() {
        StatusBarManager.shared.closePopover()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // Open About window
    private func openAbout() {
        // Close the menu bar popover first
        StatusBarManager.shared.closePopover()

        // Open About window using WindowManager (handles activation policy)
        WindowManager.shared.openAboutWindow()
    }

    // Open help documentation (GitHub)
    private func openHelp() {
        // Close the menu bar popover first
        StatusBarManager.shared.closePopover()

        if let url = URL(string: "https://github.com/yohasebe/typetalk") {
            NSWorkspace.shared.open(url)
        }
    }

    // Open settings and bring window to front
    private func openSettings() {
        // Close the menu bar popover first
        StatusBarManager.shared.closePopover()

        // Open Settings window using WindowManager (handles activation policy)
        WindowManager.shared.openSettingsWindow()
    }
}

/// Audio input source selector for menu bar (syncs with STT panel selector)
struct MenuBarAudioInputSelector: View {
    var appState: AppState
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

    var body: some View {
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
                HStack {
                    Label("System Audio", systemImage: AudioInputSourceType.systemAudio.icon)
                    if appState.selectedAudioInputSourceType == .systemAudio {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // App Audio submenu
            Menu {
                if availableApps.isEmpty {
                    Text("No apps detected")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(availableApps) { app in
                        Button(action: {
                            appState.selectedAudioInputSourceType = .applicationAudio
                            appState.selectedAudioAppBundleID = app.bundleID
                        }) {
                            HStack {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 12, height: 12)
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
                if let appIcon = currentAppIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: currentIcon)
                        .font(.caption)
                }
                Text(currentLabel)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(sourceBackgroundColor)
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .onAppear {
            loadMicrophones()
            Task {
                await appState.systemAudioCaptureService.refreshAvailableApps()
                availableApps = appState.systemAudioCaptureService.availableApps
            }
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
}

/// Compact TTS Model picker for menu bar
struct MenuBarTTSModelPicker: View {
    var appState: AppState
    @State private var availableModels: [TTSModelInfo] = []

    var body: some View {
        HStack {
            Text("Model:")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { appState.selectedTTSModel },
                set: { appState.selectedTTSModel = $0 }
            )) {
                ForEach(availableModels) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .scaleEffect(0.9, anchor: .leading)
        }
        .onAppear {
            loadModels()
        }
        .onChange(of: appState.selectedTTSProvider) { _, _ in
            loadModels()
        }
    }

    private func loadModels() {
        let service = TTSFactory.makeService(for: appState.selectedTTSProvider)
        availableModels = service.availableModels()

        // If current model is not in the list, select the default or first model
        if !availableModels.contains(where: { $0.id == appState.selectedTTSModel }) {
            if let defaultModel = availableModels.first(where: { $0.isDefault }) {
                appState.selectedTTSModel = defaultModel.id
            } else if let firstModel = availableModels.first {
                appState.selectedTTSModel = firstModel.id
            }
        }
    }
}

/// Compact TTS Voice picker for menu bar
struct MenuBarTTSVoicePicker: View {
    var appState: AppState
    @State private var availableVoices: [TTSVoice] = []
    @State private var isRefreshing = false

    var body: some View {
        HStack {
            Text("Voice:")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { appState.selectedTTSVoice },
                set: { appState.selectedTTSVoice = $0 }
            )) {
                ForEach(availableVoices) { voice in
                    Text(voiceDisplayName(voice)).tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .scaleEffect(0.9, anchor: .leading)

            // Refresh button for ElevenLabs
            if appState.selectedTTSProvider == .elevenLabs {
                Button(action: refreshVoices) {
                    if isRefreshing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh voice list")
            }
        }
        .onAppear {
            loadVoices()
            refreshVoicesInBackgroundIfNeeded()
        }
        .onChange(of: appState.selectedTTSProvider) { _, _ in
            loadVoices()
            refreshVoicesInBackgroundIfNeeded()
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

    private func refreshVoicesInBackgroundIfNeeded() {
        guard appState.selectedTTSProvider == .elevenLabs else { return }
        guard TTSVoiceCache.shared.isCacheExpired(for: .elevenLabs) else { return }

        Task {
            await ElevenLabsTTS.fetchAndCacheVoices()
            loadVoices()
        }
    }

    private func refreshVoices() {
        guard appState.selectedTTSProvider == .elevenLabs else { return }

        isRefreshing = true
        Task {
            await ElevenLabsTTS.fetchAndCacheVoices()
            loadVoices()
            isRefreshing = false
        }
    }

    private func voiceDisplayName(_ voice: TTSVoice) -> String {
        // Keep it short for menu bar
        return voice.name
    }
}

/// Audio output device selector for TTS (speaker selection)
struct MenuBarAudioOutputSelector: View {
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
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .onAppear {
            loadDevices()
        }
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

// MARK: - Menu Bar Action Button Style

/// Custom button style with hover effect for menu bar action buttons
struct MenuBarActionButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.primary.opacity(0.15)
        } else if isHovering {
            return Color.primary.opacity(0.08)
        } else {
            return Color.clear
        }
    }
}
