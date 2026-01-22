import SwiftUI
import Carbon.HIToolbox

struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ShortcutSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            TextReplacementSettingsView()
                .tabItem {
                    Label("Text Replacement", systemImage: "text.badge.plus")
                }

            APISettingsView()
                .tabItem {
                    Label("API Keys", systemImage: "key")
                }
        }
        .frame(width: 550, height: 480)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            // STT Section
            Section {
                Picker("STT Provider", selection: $appState.selectedRealtimeProvider) {
                    ForEach(availableSTTProviders) { provider in
                        Text(provider.rawValue)
                            .tag(provider)
                    }
                }
                // Note: Model is automatically reset in AppState when provider changes

                Text(appState.selectedRealtimeProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if availableSTTProviders.count < RealtimeSTTProvider.allCases.count {
                    Text("Set API keys in the API Keys tab to enable more providers")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                // STT Model selection
                STTModelPicker(appState: appState)

                // STT Language selection
                STTLanguagePicker(appState: appState)

                // Audio Input Source selection
                AudioInputSourcePicker(appState: appState)

                // Audio Input Device selection (only shown for microphone)
                AudioInputDevicePicker(appState: appState)

                // VAD Auto-Stop settings (only for Gemini, OpenAI)
                VADAutoStopSettings(appState: appState)

                // STT Panel behavior settings
                STTPanelBehaviorSettings(appState: appState)
            } header: {
                Text("Speech-to-Text")
            }

            // TTS Section
            Section {
                Picker("TTS Provider", selection: $appState.selectedTTSProvider) {
                    ForEach(availableTTSProviders) { provider in
                        Text(provider.rawValue)
                            .tag(provider)
                    }
                }
                // Note: Voice and model are automatically reset in AppState when provider changes

                Text(appState.selectedTTSProvider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if availableTTSProviders.count < TTSProvider.allCases.count {
                    Text("Set API keys in the API Keys tab to enable more providers")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                // Model selection based on provider
                TTSModelPicker(appState: appState)

                // Voice selection based on provider
                TTSVoicePicker(appState: appState)

                // Speed control
                TTSSpeedSlider(appState: appState)

                // TTS Language selection (ElevenLabs only)
                TTSLanguagePicker(appState: appState)

                // Audio Output Device selection
                AudioOutputDevicePicker(appState: appState)

                // TTS Panel behavior settings
                TTSPanelBehaviorSettings(appState: appState)
            } header: {
                Text("Text-to-Speech")
            }

            // Appearance Section
            Section {
                PanelAppearanceSettings(appState: appState)
            } header: {
                Text("Appearance")
            }

            // Subtitle Mode Section
            Section {
                SubtitleModeSettings(appState: appState)
            } header: {
                Text("Subtitle Mode")
            }

            // Startup Section
            Section {
                LaunchAtLoginToggle()
            } header: {
                Text("Startup")
            }
        }
        .formStyle(.grouped)
        .padding()
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
        guard provider.envKeyName != nil else { return true }
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

    private func hasTTSAPIKey(for provider: TTSProvider) -> Bool {
        guard provider.envKeyName != nil else { return true }
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
}

struct ShortcutSettingsView: View {
    @Environment(AppState.self) var appState
    @State private var sttKeyCombo: KeyCombo = .sttDefault
    @State private var ttsKeyCombo: KeyCombo = .ttsDefault
    @State private var ocrKeyCombo: KeyCombo = .ocrDefault
    @State private var subtitleKeyCombo: KeyCombo = .subtitleDefault
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared

    var body: some View {
        ScrollView {
            Form {
                Section {
                    ShortcutRecorderView(title: "Toggle STT Panel", keyCombo: $sttKeyCombo)
                        .onChange(of: sttKeyCombo) { _, newValue in
                            appState.hotKeyService?.sttKeyCombo = newValue
                        }

                    ShortcutRecorderView(title: "Toggle TTS Panel", keyCombo: $ttsKeyCombo)
                        .onChange(of: ttsKeyCombo) { _, newValue in
                            appState.hotKeyService?.ttsKeyCombo = newValue
                        }

                    ShortcutRecorderView(title: "OCR Region to TTS", keyCombo: $ocrKeyCombo)
                        .onChange(of: ocrKeyCombo) { _, newValue in
                            appState.hotKeyService?.ocrKeyCombo = newValue
                        }

                    ShortcutRecorderView(title: "Toggle Subtitle Mode", keyCombo: $subtitleKeyCombo)
                        .onChange(of: subtitleKeyCombo) { _, newValue in
                            appState.hotKeyService?.subtitleKeyCombo = newValue
                        }
                } header: {
                    Text("Global Hotkeys")
                } footer: {
                    Text("Click on a shortcut and press a new key combination to change it. Shortcuts must include at least one modifier key (⌘, ⌥, ⌃, or ⇧).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // STT Panel Shortcuts
                Section {
                    ForEach(ShortcutAction.allCases.filter { $0.category == "STT Panel" }, id: \.self) { action in
                        PanelShortcutRow(action: action, manager: shortcutManager)
                    }
                } header: {
                    Text("STT Panel Shortcuts")
                } footer: {
                    Text("Shortcuts available when the STT transcription panel is open.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // TTS Panel Shortcuts
                Section {
                    ForEach(ShortcutAction.allCases.filter { $0.category == "TTS Panel" }, id: \.self) { action in
                        PanelShortcutRow(action: action, manager: shortcutManager)
                    }
                } header: {
                    Text("TTS Panel Shortcuts")
                } footer: {
                    Text("Shortcuts available when the TTS panel is open. STT and TTS panels are mutually exclusive, so they can share the same shortcuts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Common Shortcuts (both panels)
                Section {
                    ForEach(ShortcutAction.allCases.filter { $0.category == "Common" }, id: \.self) { action in
                        PanelShortcutRow(action: action, manager: shortcutManager)
                    }
                } header: {
                    Text("Common Shortcuts")
                } footer: {
                    Text("Shortcuts available in both STT and TTS panels.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("Reset Global Hotkeys") {
                        sttKeyCombo = .sttDefault
                        ttsKeyCombo = .ttsDefault
                        ocrKeyCombo = .ocrDefault
                        subtitleKeyCombo = .subtitleDefault
                        appState.hotKeyService?.sttKeyCombo = .sttDefault
                        appState.hotKeyService?.ttsKeyCombo = .ttsDefault
                        appState.hotKeyService?.ocrKeyCombo = .ocrDefault
                        appState.hotKeyService?.subtitleKeyCombo = .subtitleDefault
                    }

                    Button("Reset Panel Shortcuts") {
                        shortcutManager.resetAllShortcuts()
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .onAppear {
            // Load current shortcuts from hotKeyService
            if let service = appState.hotKeyService {
                sttKeyCombo = service.sttKeyCombo
                ttsKeyCombo = service.ttsKeyCombo
                ocrKeyCombo = service.ocrKeyCombo
                subtitleKeyCombo = service.subtitleKeyCombo
            }
        }
    }
}

/// Row for editing a panel shortcut
struct PanelShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var manager: ShortcutSettingsManager
    @State private var isRecording = false

    private var currentShortcut: CustomShortcut {
        manager.shortcut(for: action)
    }

    var body: some View {
        HStack {
            Text(action.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            PanelShortcutRecorder(
                shortcut: currentShortcut,
                isRecording: $isRecording,
                onRecord: { newShortcut in
                    manager.setShortcut(newShortcut, for: action)
                }
            )
            .frame(width: 120)

            Button(action: {
                manager.resetShortcut(for: action)
            }) {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
        }
    }
}

/// Shortcut recorder for panel shortcuts (captures key + modifiers)
struct PanelShortcutRecorder: View {
    let shortcut: CustomShortcut
    @Binding var isRecording: Bool
    let onRecord: (CustomShortcut) -> Void

    var body: some View {
        Button(action: {
            isRecording = true
        }) {
            Text(isRecording ? "Press keys..." : shortcut.displayString)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .focusable()
        .onKeyPress { keyPress in
            guard isRecording else { return .ignored }

            // Get modifier flags
            var modifiers: UInt = 0
            if keyPress.modifiers.contains(.command) {
                modifiers |= UInt(NSEvent.ModifierFlags.command.rawValue)
            }
            if keyPress.modifiers.contains(.shift) {
                modifiers |= UInt(NSEvent.ModifierFlags.shift.rawValue)
            }
            if keyPress.modifiers.contains(.option) {
                modifiers |= UInt(NSEvent.ModifierFlags.option.rawValue)
            }
            if keyPress.modifiers.contains(.control) {
                modifiers |= UInt(NSEvent.ModifierFlags.control.rawValue)
            }

            // Get key code from the key
            let keyCode = keyCodeFromKeyEquivalent(keyPress.key)

            // Only accept if we have at least one modifier (or it's a special key)
            if modifiers != 0 || isSpecialKey(keyCode) {
                let newShortcut = CustomShortcut(keyCode: keyCode, modifiers: modifiers)
                if newShortcut.isValid {
                    onRecord(newShortcut)
                }
            }

            isRecording = false
            return .handled
        }
        .onExitCommand {
            isRecording = false
        }
    }

    private func keyCodeFromKeyEquivalent(_ key: KeyEquivalent) -> Int {
        let char = String(key.character).lowercased()

        switch char {
        case "a": return kVK_ANSI_A
        case "b": return kVK_ANSI_B
        case "c": return kVK_ANSI_C
        case "d": return kVK_ANSI_D
        case "e": return kVK_ANSI_E
        case "f": return kVK_ANSI_F
        case "g": return kVK_ANSI_G
        case "h": return kVK_ANSI_H
        case "i": return kVK_ANSI_I
        case "j": return kVK_ANSI_J
        case "k": return kVK_ANSI_K
        case "l": return kVK_ANSI_L
        case "m": return kVK_ANSI_M
        case "n": return kVK_ANSI_N
        case "o": return kVK_ANSI_O
        case "p": return kVK_ANSI_P
        case "q": return kVK_ANSI_Q
        case "r": return kVK_ANSI_R
        case "s": return kVK_ANSI_S
        case "t": return kVK_ANSI_T
        case "u": return kVK_ANSI_U
        case "v": return kVK_ANSI_V
        case "w": return kVK_ANSI_W
        case "x": return kVK_ANSI_X
        case "y": return kVK_ANSI_Y
        case "z": return kVK_ANSI_Z
        case "0": return kVK_ANSI_0
        case "1": return kVK_ANSI_1
        case "2": return kVK_ANSI_2
        case "3": return kVK_ANSI_3
        case "4": return kVK_ANSI_4
        case "5": return kVK_ANSI_5
        case "6": return kVK_ANSI_6
        case "7": return kVK_ANSI_7
        case "8": return kVK_ANSI_8
        case "9": return kVK_ANSI_9
        case ".": return kVK_ANSI_Period
        case ",": return kVK_ANSI_Comma
        case "/": return kVK_ANSI_Slash
        case ";": return kVK_ANSI_Semicolon
        case "=": return kVK_ANSI_Equal
        case "-": return kVK_ANSI_Minus
        case "\r", "\n": return kVK_Return
        case "\u{1B}": return kVK_Escape
        case "\u{7F}": return kVK_Delete
        case "\t": return kVK_Tab
        case " ": return kVK_Space
        default: return 0
        }
    }

    private func isSpecialKey(_ keyCode: Int) -> Bool {
        return keyCode == kVK_Return ||
               keyCode == kVK_Escape ||
               keyCode == kVK_Delete ||
               keyCode == kVK_Tab ||
               keyCode == kVK_Space
    }
}

/// Voice picker for TTS provider
struct TTSVoicePicker: View {
    @Bindable var appState: AppState
    @State private var availableVoices: [TTSVoice] = []
    @State private var isRefreshing = false

    var body: some View {
        HStack {
            Picker("Voice", selection: $appState.selectedTTSVoice) {
                if appState.selectedTTSProvider == .macOS {
                    // macOS: Show voices grouped by quality with section headers
                    ForEach(voicesWithSections, id: \.id) { item in
                        if item.isSection {
                            Divider()
                            Text(item.sectionTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let voice = item.voice {
                            Text(voiceDisplayName(voice))
                                .tag(voice.id)
                        }
                    }
                } else {
                    // Other providers: Simple list
                    ForEach(availableVoices) { voice in
                        Text(voiceDisplayName(voice))
                            .tag(voice.id)
                    }
                }
            }

            if appState.selectedTTSProvider == .elevenLabs {
                Button(action: refreshVoices) {
                    if isRefreshing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh voice list from API")
            }
        }
        .onAppear {
            loadVoices()
            refreshVoicesInBackgroundIfNeeded()
        }
        .onChange(of: appState.selectedTTSProvider) { _, _ in
            // Reset voice when provider changes
            loadVoices()
            refreshVoicesInBackgroundIfNeeded()
        }
    }

    /// Voice item or section header for grouped display
    private struct VoiceListItem: Identifiable {
        let id: String
        let voice: TTSVoice?
        let isSection: Bool
        let sectionTitle: String

        static func section(_ title: String) -> VoiceListItem {
            VoiceListItem(id: "section_\(title)", voice: nil, isSection: true, sectionTitle: title)
        }

        static func voice(_ voice: TTSVoice) -> VoiceListItem {
            VoiceListItem(id: voice.id, voice: voice, isSection: false, sectionTitle: "")
        }
    }

    /// Check if there are multiple quality tiers (to decide whether to show separators)
    private var hasMultipleQualityTiers: Bool {
        let nonDefaultVoices = availableVoices.filter { !$0.isDefault }
        let qualities = Set(nonDefaultVoices.map { $0.quality })
        return qualities.count > 1
    }

    /// Generate voice list with section headers for quality tiers
    private var voicesWithSections: [VoiceListItem] {
        var items: [VoiceListItem] = []
        var currentQuality: VoiceQuality?

        // Only show separators if there are multiple quality tiers
        let showSeparators = hasMultipleQualityTiers

        for voice in availableVoices {
            // Add section header when quality changes (skip for Auto voice)
            if showSeparators && !voice.isDefault && voice.quality != currentQuality {
                currentQuality = voice.quality
                let title: String
                switch voice.quality {
                case .premium:
                    title = "── Premium ──"
                case .enhanced:
                    title = "── Enhanced ──"
                case .standard:
                    title = "── Standard ──"
                }
                items.append(.section(title))
            }
            items.append(.voice(voice))
        }

        return items
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
        // Only show language suffix for ElevenLabs and macOS (where it's meaningful)
        // OpenAI and Gemini voices don't need language suffix
        if voice.language.isEmpty ||
           appState.selectedTTSProvider == .openAI ||
           appState.selectedTTSProvider == .gemini {
            return voice.name
        } else {
            return "\(voice.name) (\(voice.language))"
        }
    }
}

/// Model picker for STT provider
struct STTModelPicker: View {
    @Bindable var appState: AppState
    @State private var availableModels: [RealtimeSTTModelInfo] = []

    var body: some View {
        Picker("Model", selection: $appState.selectedRealtimeSTTModel) {
            ForEach(availableModels) { model in
                Text(modelDisplayName(model))
                    .tag(model.id)
            }
        }
        .onAppear {
            loadModels()
        }
        .onChange(of: appState.selectedRealtimeProvider) { _, _ in
            loadModels()
        }
    }

    private func loadModels() {
        let service = RealtimeSTTFactory.makeService(for: appState.selectedRealtimeProvider)
        availableModels = service.availableModels()

        // If current model is not in the list, select the default or first model
        if !availableModels.contains(where: { $0.id == appState.selectedRealtimeSTTModel }) {
            if let defaultModel = availableModels.first(where: { $0.isDefault }) {
                appState.selectedRealtimeSTTModel = defaultModel.id
            } else if let firstModel = availableModels.first {
                appState.selectedRealtimeSTTModel = firstModel.id
            }
        }
    }

    private func modelDisplayName(_ model: RealtimeSTTModelInfo) -> String {
        if model.description.isEmpty {
            return model.name
        } else {
            return "\(model.name) - \(model.description)"
        }
    }
}

/// Model picker for TTS provider
struct TTSModelPicker: View {
    @Bindable var appState: AppState
    @State private var availableModels: [TTSModelInfo] = []

    var body: some View {
        Picker("Model", selection: $appState.selectedTTSModel) {
            ForEach(availableModels) { model in
                Text(modelDisplayName(model))
                    .tag(model.id)
            }
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

    private func modelDisplayName(_ model: TTSModelInfo) -> String {
        if model.description.isEmpty {
            return model.name
        } else {
            return "\(model.name) - \(model.description)"
        }
    }
}

/// Speed slider for TTS provider
struct TTSSpeedSlider: View {
    @Bindable var appState: AppState
    @State private var currentService: TTSService?

    // Get speed range for current provider
    private var speedRange: ClosedRange<Double> {
        // Use a standard range for UI, actual conversion happens in each provider
        0.5...2.0
    }

    private var supportsSpeed: Bool {
        switch appState.selectedTTSProvider {
        case .openAI:
            // gpt-4o-mini-tts (default when empty) doesn't support speed
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            return model != "gpt-4o-mini-tts"
        case .grok:
            return false  // Grok Voice Agent doesn't support speed control
        case .macOS, .gemini, .elevenLabs:
            return true
        }
    }

    private var speedHelpText: String? {
        switch appState.selectedTTSProvider {
        case .openAI:
            let model = appState.selectedTTSModel.isEmpty ? "gpt-4o-mini-tts" : appState.selectedTTSModel
            if model == "gpt-4o-mini-tts" {
                return "Speed control not available for GPT-4o Mini TTS. Use TTS-1 or TTS-1 HD for speed control."
            }
            return nil
        case .gemini:
            return "Gemini uses natural language pace control (approximate)."
        case .elevenLabs:
            return "ElevenLabs has limited speed range (0.7x-1.2x mapped)."
        case .grok:
            return "Grok Voice Agent does not support speed control."
        case .macOS:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speed")
                Spacer()
                Text(speedDisplayText)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                Slider(
                    value: $appState.selectedTTSSpeed,
                    in: speedRange,
                    step: 0.1
                ) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Slow")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } maximumValueLabel: {
                    Text("Fast")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .disabled(!supportsSpeed)
                .help(speedTooltip)

                Button("Reset") {
                    appState.selectedTTSSpeed = 1.0
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let helpText = speedHelpText {
                Text(helpText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // Tooltip text for speed slider
    private var speedTooltip: String {
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
        case .grok:
            return "Grok Voice Agent does not support speed control"
        }
    }

    private var speedDisplayText: String {
        if !supportsSpeed {
            return "N/A"
        }
        return String(format: "%.1fx", appState.selectedTTSSpeed)
    }
}

/// Toggle for launch at login setting
struct LaunchAtLoginToggle: View {
    @State private var isEnabled: Bool = LaunchAtLoginService.shared.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at Login", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in
                    LaunchAtLoginService.shared.isEnabled = newValue
                }
                .disabled(!LaunchAtLoginService.shared.isAvailable)

            if LaunchAtLoginService.shared.isAvailable {
                Text("SpeechDock will start automatically when you log in")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Launch at login requires macOS 13 or later")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            // Sync state on appear
            isEnabled = LaunchAtLoginService.shared.isEnabled
        }
    }
}

/// Language picker for STT provider
struct STTLanguagePicker: View {
    @Bindable var appState: AppState

    /// Get supported languages for the current provider
    private var supportedLanguages: [LanguageCode] {
        LanguageCode.supportedLanguages(for: appState.selectedRealtimeProvider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Language", selection: $appState.selectedSTTLanguage) {
                ForEach(supportedLanguages) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .onAppear {
                // Ensure valid selection on appear
                ensureValidLanguageSelection()
            }
            .onChange(of: appState.selectedRealtimeProvider) { _, newProvider in
                // Reset to default language if current selection is not supported
                let supported = LanguageCode.supportedLanguages(for: newProvider)
                if let currentLang = LanguageCode(rawValue: appState.selectedSTTLanguage),
                   !supported.contains(currentLang) {
                    appState.selectedSTTLanguage = LanguageCode.defaultLanguage(for: newProvider).rawValue
                } else if appState.selectedSTTLanguage.isEmpty && !LanguageCode.supportsAutoDetection(for: newProvider) {
                    // Auto ("") not supported, switch to default
                    appState.selectedSTTLanguage = LanguageCode.defaultLanguage(for: newProvider).rawValue
                }
            }

            Text(languageHelpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Ensure the current language selection is valid for the provider
    private func ensureValidLanguageSelection() {
        let supported = supportedLanguages

        // Check if current selection is valid
        if let currentLang = LanguageCode(rawValue: appState.selectedSTTLanguage) {
            if supported.contains(currentLang) {
                return  // Selection is valid
            }
        }

        // Current selection is invalid (e.g., Auto for macOS), reset to default
        appState.selectedSTTLanguage = LanguageCode.defaultLanguage(for: appState.selectedRealtimeProvider).rawValue
    }

    private var languageHelpText: String {
        switch appState.selectedRealtimeProvider {
        case .macOS:
            return "Auto uses system locale. Select a specific language for better accuracy."
        case .openAI:
            return "Auto detects the language. Specifying a language can improve accuracy."
        case .gemini:
            return "Auto detects the language. Note: Portuguese is not supported."
        case .elevenLabs:
            return "Auto detects the language. Specifying a language can improve accuracy."
        case .grok:
            return "Auto detects the language (100+ languages supported)."
        }
    }
}

/// Language picker for TTS provider (only shown for ElevenLabs)
struct TTSLanguagePicker: View {
    @Bindable var appState: AppState

    var body: some View {
        if appState.selectedTTSProvider == .elevenLabs {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Language", selection: $appState.selectedTTSLanguage) {
                    ForEach(LanguageCode.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }

                Text("Specifies the output language for speech synthesis.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Audio input source picker for STT (Microphone, System Audio only in Settings)
/// App Audio is only available in Menu Bar and STT Panel
struct AudioInputSourcePicker: View {
    @Bindable var appState: AppState

    /// Source types available in Settings (excludes App Audio)
    private let availableSourceTypes: [AudioInputSourceType] = [.microphone, .systemAudio]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Audio Source", selection: $appState.selectedAudioInputSourceType) {
                ForEach(availableSourceTypes) { sourceType in
                    Label(sourceType.rawValue, systemImage: sourceType.icon)
                        .tag(sourceType)
                }
            }

            Text(appState.selectedAudioInputSourceType.description)
                .font(.caption)
                .foregroundColor(.secondary)

            // Note about system audio permission
            if appState.selectedAudioInputSourceType == .systemAudio {
                Text("System Audio requires Screen Recording permission.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Note about App Audio availability
            Text("App-specific audio capture is available in the menu bar and STT panel.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear {
            // If App Audio was selected elsewhere, reset to Microphone in Settings
            if appState.selectedAudioInputSourceType == .applicationAudio {
                appState.selectedAudioInputSourceType = .microphone
            }
        }
    }
}

/// Audio input device picker for STT (microphone selection)
struct AudioInputDevicePicker: View {
    @Bindable var appState: AppState
    @State private var availableDevices: [AudioInputDevice] = []

    var body: some View {
        // Only show microphone picker when microphone is selected as source
        if appState.selectedAudioInputSourceType == .microphone {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Microphone", selection: $appState.selectedAudioInputDeviceUID) {
                    ForEach(availableDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Text("Select the microphone device for speech recognition.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .onAppear {
                loadDevices()
            }
        }
    }

    private func loadDevices() {
        availableDevices = appState.audioInputManager.availableInputDevices()

        // If selected device is not in the list, reset to system default
        if !availableDevices.contains(where: { $0.uid == appState.selectedAudioInputDeviceUID }) {
            appState.selectedAudioInputDeviceUID = ""
        }
    }
}

/// Audio output device picker for TTS (speaker selection)
struct AudioOutputDevicePicker: View {
    @Bindable var appState: AppState
    @State private var availableDevices: [AudioOutputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Audio Output", selection: $appState.selectedAudioOutputDeviceUID) {
                ForEach(availableDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }

            Text("Select the audio output device for speech playback.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            loadDevices()
        }
    }

    private func loadDevices() {
        availableDevices = AudioOutputManager.shared.availableOutputDevices()

        // If selected device is not in the list, reset to system default
        if !availableDevices.contains(where: { $0.uid == appState.selectedAudioOutputDeviceUID }) {
            appState.selectedAudioOutputDeviceUID = ""
        }
    }
}

/// VAD Auto-Stop settings (only shown for providers that use VAD)
struct VADAutoStopSettings: View {
    @Bindable var appState: AppState

    /// Check if current provider uses VAD for auto-stop
    private var supportsVADAutoStop: Bool {
        [.gemini, .openAI].contains(appState.selectedRealtimeProvider)
    }

    var body: some View {
        if supportsVADAutoStop {
            VStack(alignment: .leading, spacing: 12) {
                Text("Auto-Stop Settings")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Minimum recording time
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min. recording time")
                        Spacer()
                        Text("\(Int(appState.vadMinimumRecordingTime))s")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    HStack {
                        Text("5s")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Slider(
                            value: $appState.vadMinimumRecordingTime,
                            in: 5...60,
                            step: 5
                        )

                        Text("60s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Text("Recording must reach this duration before auto-stop activates.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Silence duration
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Silence duration")
                        Spacer()
                        Text("\(Int(appState.vadSilenceDuration))s")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    HStack {
                        Text("1s")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Slider(
                            value: $appState.vadSilenceDuration,
                            in: 1...10,
                            step: 1
                        )

                        Text("10s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Text("Duration of silence required to trigger auto-stop.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Reset button
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        appState.vadMinimumRecordingTime = 10.0
                        appState.vadSilenceDuration = 3.0
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// STT Panel behavior settings
struct STTPanelBehaviorSettings: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Panel Behavior")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Toggle(isOn: $appState.sttAutoStart) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-start recording")
                    Text("When enabled, recording starts automatically when the STT panel opens.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Toggle(isOn: $appState.closePanelAfterPaste) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Close panel after paste")
                    Text("When enabled, the STT panel closes automatically after pasting text.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// TTS Panel behavior settings
struct TTSPanelBehaviorSettings: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Panel Behavior")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Toggle(isOn: $appState.ttsAutoSpeak) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-speak on panel open")
                    Text("When enabled, TTS starts speaking automatically when the panel opens with text.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Panel appearance settings (font size for STT/TTS panels)
struct PanelAppearanceSettings: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Text Font Size")
                Spacer()
                Text("\(Int(appState.panelTextFontSize)) pt")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                Slider(
                    value: $appState.panelTextFontSize,
                    in: 10...24,
                    step: 1
                ) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("A")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } maximumValueLabel: {
                    Text("A")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }

                Button("Reset") {
                    appState.panelTextFontSize = 13.0
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Text("Font size for text in STT and TTS panels.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }

        Picker("Panel Style", selection: $appState.panelStyle) {
            ForEach(PanelStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style)
            }
        }
        .onChange(of: appState.panelStyle) { _, _ in
            // Close any open panel when style changes to avoid rendering issues
            // The panel will reopen with the new style when user opens it again
            if appState.floatingWindowManager.isVisible {
                appState.floatingWindowManager.closePanel()
            }
        }

        Text("Floating: Always-on-top borderless panels. Standard Window: Regular windows with title bar. Only one panel (STT or TTS) can be open at a time.")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}

/// Subtitle Mode settings
struct SubtitleModeSettings: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Enable/Disable toggle
            Toggle(isOn: $appState.subtitleModeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Subtitle Mode")
                    Text("Display real-time transcription as subtitles during recording.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Position picker
            Picker("Position", selection: $appState.subtitlePosition) {
                ForEach(SubtitlePosition.allCases) { position in
                    Text(position.displayName).tag(position)
                }
            }

            // Font size slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(appState.subtitleFontSize)) pt")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Slider(
                        value: $appState.subtitleFontSize,
                        in: 18...48,
                        step: 2
                    ) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("A")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } maximumValueLabel: {
                        Text("A")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }

                    Button("Reset") {
                        appState.subtitleFontSize = 28.0
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            // Text opacity slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Text Opacity")
                    Spacer()
                    Text("\(Int(appState.subtitleOpacity * 100))%")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                Slider(
                    value: $appState.subtitleOpacity,
                    in: 0.3...1.0,
                    step: 0.05
                )
            }

            // Background opacity slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Background Opacity")
                    Spacer()
                    Text("\(Int(appState.subtitleBackgroundOpacity * 100))%")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                Slider(
                    value: $appState.subtitleBackgroundOpacity,
                    in: 0.1...0.9,
                    step: 0.05
                )
            }

            // Max lines picker
            Picker("Max Lines", selection: $appState.subtitleMaxLines) {
                ForEach(2...6, id: \.self) { lines in
                    Text("\(lines) lines").tag(lines)
                }
            }

            // Hide panel when active toggle
            Toggle(isOn: $appState.subtitleHidePanelWhenActive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide STT Panel when active")
                    Text("Temporarily hide the STT panel when subtitle mode is active.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Reset all button
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    appState.subtitleModeEnabled = false
                    appState.subtitlePosition = .bottom
                    appState.subtitleFontSize = 28.0
                    appState.subtitleOpacity = 0.85
                    appState.subtitleBackgroundOpacity = 0.5
                    appState.subtitleMaxLines = 3
                    appState.subtitleHidePanelWhenActive = true
                }
                .font(.caption)
            }
        }
    }
}
