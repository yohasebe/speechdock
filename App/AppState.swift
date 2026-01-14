import SwiftUI
import Combine
import AVFoundation
import ApplicationServices

enum TranscriptionState: Equatable {
    case idle
    case recording
    case processing
    case result(String)
    case error(String)

    var statusText: String {
        switch self {
        case .idle: return ""
        case .recording: return "Recording..."
        case .processing: return "Processing..."
        case .result: return ""
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // MARK: - STT State
    var isRecording = false
    var currentTranscription = ""
    var transcriptionState: TranscriptionState = .idle
    var recordingDuration: TimeInterval = 0  // Cumulative recording duration
    private var recordingStartTime: Date?
    private var durationTimer: Timer?

    // Realtime STT provider and model selection
    var selectedRealtimeProvider: RealtimeSTTProvider = .macOS {
        didSet {
            guard !isLoadingPreferences else { return }
            // Reset model to default for new provider
            let service = RealtimeSTTFactory.makeService(for: selectedRealtimeProvider)
            if let defaultModel = service.availableModels().first(where: { $0.isDefault }) {
                selectedRealtimeSTTModel = defaultModel.id
            } else if let firstModel = service.availableModels().first {
                selectedRealtimeSTTModel = firstModel.id
            } else {
                selectedRealtimeSTTModel = ""
            }
            savePreferences()
        }
    }
    var selectedRealtimeSTTModel: String = "" {  // Empty means use default
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // Legacy batch STT settings (kept for compatibility)
    var selectedProvider: STTProvider = .openAI {
        didSet {
            guard !isLoadingPreferences else { return }
            if !selectedProvider.availableModels.contains(selectedModel) {
                selectedModel = selectedProvider.defaultModel
            }
            savePreferences()
        }
    }
    var selectedModel: STTModel = .gpt4oMiniTranscribe {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // MARK: - TTS State
    var ttsState: TTSState = .idle
    var ttsText = ""
    var selectedTTSProvider: TTSProvider = .macOS {
        didSet {
            guard !isLoadingPreferences else { return }
            // Reset voice and model to defaults for new provider
            let service = TTSFactory.makeService(for: selectedTTSProvider)

            // Set default voice
            if let defaultVoice = service.availableVoices().first(where: { $0.isDefault }) {
                selectedTTSVoice = defaultVoice.id
            } else if let firstVoice = service.availableVoices().first {
                selectedTTSVoice = firstVoice.id
            } else {
                selectedTTSVoice = ""
            }

            // Set default model
            if let defaultModel = service.availableModels().first(where: { $0.isDefault }) {
                selectedTTSModel = defaultModel.id
            } else if let firstModel = service.availableModels().first {
                selectedTTSModel = firstModel.id
            } else {
                selectedTTSModel = ""
            }

            // Clear audio cache when provider changes
            lastSynthesizedText = ""
            ttsService = nil

            savePreferences()
        }
    }
    var selectedTTSVoice: String = "" {  // Empty means auto-detect
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    var selectedTTSModel: String = "" {  // Empty means use default
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    var selectedTTSSpeed: Double = 1.0 {  // Speed multiplier (1.0 = normal)
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    var showTTSWindow = false
    var lastSynthesizedText = ""  // Track last synthesized text for cache
    var isSavingAudio = false  // Loading state for audio save

    // MARK: - Language Settings
    var selectedSTTLanguage: String = "" {  // "" = Auto
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    var selectedTTSLanguage: String = "" {  // "" = Auto (only used by ElevenLabs)
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // MARK: - Audio Input Settings
    var selectedAudioInputDeviceUID: String = "" {  // "" = System Default
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // MARK: - Audio Output Settings
    var selectedAudioOutputDeviceUID: String = "" {  // "" = System Default
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Audio input source type (microphone, system audio, or app audio)
    var selectedAudioInputSourceType: AudioInputSourceType = .microphone {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Bundle ID of the selected app for app-specific audio capture
    var selectedAudioAppBundleID: String = "" {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Current audio input source configuration
    var currentAudioInputSource: AudioInputSource {
        switch selectedAudioInputSourceType {
        case .microphone:
            return .microphone
        case .systemAudio:
            return .systemAudio
        case .applicationAudio:
            let appName = SystemAudioCaptureService.shared.availableApps
                .first { $0.bundleID == selectedAudioAppBundleID }?.name ?? "App"
            return .app(bundleID: selectedAudioAppBundleID, name: appName)
        }
    }

    let audioInputManager = AudioInputManager.shared
    let systemAudioCaptureService = SystemAudioCaptureService.shared

    // MARK: - VAD Auto-Stop Settings
    /// Minimum recording duration before VAD auto-stop becomes active (seconds)
    var vadMinimumRecordingTime: Double = 10.0 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Duration of silence required to trigger auto-stop (seconds)
    var vadSilenceDuration: Double = 3.0 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Whether to close STT panel after pasting text (default: false = keep panel open)
    var closePanelAfterPaste: Bool = false {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Font size for STT/TTS panel text areas (default: 13 = system font size)
    var panelTextFontSize: Double = 13.0 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // MARK: - Permission Status
    var hasMicrophonePermission: Bool = false
    var hasAccessibilityPermission: Bool = false

    /// Update permission status (call periodically or after permission changes)
    func updatePermissionStatus() {
        hasMicrophonePermission = checkMicrophonePermission()
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    private func checkMicrophonePermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized
    }

    // MARK: - Common State
    var isProcessing = false
    var errorMessage: String?
    var showFloatingWindow = false

    let apiKeyManager = APIKeyManager.shared
    let floatingWindowManager = FloatingWindowManager()

    // Expose hotKeyService for settings UI
    private(set) var hotKeyService: HotKeyService?
    private var realtimeSTTService: RealtimeSTTService?
    private var isLoadingPreferences = false  // Flag to prevent saving during load
    private var ttsService: TTSService?

    private init() {
        loadPreferences()
        refreshVoiceCachesInBackground()
        prefetchAvailableAppsInBackground()
        updatePermissionStatus()
    }

    /// Refresh voice caches in background (non-blocking)
    private func refreshVoiceCachesInBackground() {
        // Check cache status on main actor first
        let shouldRefreshElevenLabs = TTSVoiceCache.shared.isCacheExpired(for: .elevenLabs)

        Task.detached(priority: .background) {
            // Refresh ElevenLabs voices if cache is expired or empty
            if shouldRefreshElevenLabs {
                await ElevenLabsTTS.fetchAndCacheVoices()
            }
        }
    }

    /// Prefetch available apps for App Audio in background (non-blocking)
    /// This preloads SCShareableContent and app icons to avoid delay on first menu open
    private func prefetchAvailableAppsInBackground() {
        Task {
            await systemAudioCaptureService.refreshAvailableApps()
        }
    }

    func setupHotKey(_ service: HotKeyService) {
        hotKeyService = service
        service.delegate = self
        service.registerAllHotKeys()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isProcessing else { return }

        // Mutual exclusivity: close TTS panel and stop TTS if active
        if showTTSWindow || ttsState == .speaking || ttsState == .paused || ttsState == .loading {
            stopTTS()
            floatingWindowManager.hideFloatingWindow()
            showTTSWindow = false
            ttsText = ""
        }

        errorMessage = nil
        currentTranscription = ""

        // Start realtime STT FIRST to ensure audio capture begins immediately
        Task {
            await startRealtimeSTT()

            // After audio capture has started, update UI state on main thread
            await MainActor.run {
                isRecording = true
                transcriptionState = .recording

                // Start duration timer
                recordingDuration = 0
                recordingStartTime = Date()
                durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self, let startTime = self.recordingStartTime else { return }
                        self.recordingDuration = Date().timeIntervalSince(startTime)
                    }
                }

                // Only show floating window if not already visible
                // This prevents resetting @State variables when resuming recording
                if !showFloatingWindow {
                    showFloatingWindowWithState()
                }
            }
        }
    }

    private func startRealtimeSTT() async {
        // Create realtime STT service
        realtimeSTTService = RealtimeSTTFactory.makeService(for: selectedRealtimeProvider)
        realtimeSTTService?.delegate = self

        // Apply selected model if set
        if !selectedRealtimeSTTModel.isEmpty {
            realtimeSTTService?.selectedModel = selectedRealtimeSTTModel
        }

        // Apply selected language if set
        if !selectedSTTLanguage.isEmpty {
            realtimeSTTService?.selectedLanguage = selectedSTTLanguage
        }

        // Configure audio source based on settings
        switch selectedAudioInputSourceType {
        case .microphone:
            realtimeSTTService?.audioSource = .microphone
            realtimeSTTService?.audioInputDeviceUID = selectedAudioInputDeviceUID
        case .systemAudio, .applicationAudio:
            realtimeSTTService?.audioSource = .external
            systemAudioCaptureService.delegate = self
        }

        // Apply VAD auto-stop settings
        realtimeSTTService?.vadMinimumRecordingTime = vadMinimumRecordingTime
        realtimeSTTService?.vadSilenceDuration = vadSilenceDuration

        do {
            try await realtimeSTTService?.startListening()

            // Start system audio capture if needed
            if selectedAudioInputSourceType == .systemAudio {
                try await systemAudioCaptureService.startCapturingSystemAudio()
            } else if selectedAudioInputSourceType == .applicationAudio, !selectedAudioAppBundleID.isEmpty {
                try await systemAudioCaptureService.startCapturingAppAudio(bundleID: selectedAudioAppBundleID)
            }
        } catch {
            errorMessage = error.localizedDescription
            transcriptionState = .error(error.localizedDescription)
        }
    }

    private func stopRecording() {
        isRecording = false

        // Stop duration timer
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil

        // Check if this provider does "record then transcribe" (needs processing state)
        let needsProcessingState = [.gemini, .openAI, .localWhisper].contains(selectedRealtimeProvider)

        if needsProcessingState {
            // Set processing state - the delegate will update when transcription completes
            transcriptionState = .processing
            // Keep realtimeSTTService alive - it will be cleared in didReceiveFinalResult
            realtimeSTTService?.stopListening()
        } else {
            // Realtime providers (macOS, ElevenLabs) - immediate result
            realtimeSTTService?.stopListening()
            realtimeSTTService = nil

            // If we have transcription, show result state
            if !currentTranscription.isEmpty {
                transcriptionState = .result(currentTranscription)
            } else {
                transcriptionState = .idle
            }
        }

        // Stop system audio capture if active
        if systemAudioCaptureService.isCapturing {
            Task {
                await systemAudioCaptureService.stopCapturing()
            }
        }
    }

    /// Stop recording and immediately insert the text
    func stopRecordingAndInsert(_ text: String) {
        // Stop recording first
        isRecording = false
        realtimeSTTService?.stopListening()
        realtimeSTTService = nil
        transcriptionState = .idle

        // Stop system audio capture if active
        if systemAudioCaptureService.isCapturing {
            Task {
                await systemAudioCaptureService.stopCapturing()
            }
        }

        // Then hide window and paste
        hideWindowAndPaste(text)
    }

    private func showFloatingWindowWithState() {
        floatingWindowManager.showFloatingWindow(
            appState: self,
            onConfirm: { [weak self] text in
                self?.hideWindowAndPaste(text)
            },
            onCancel: { [weak self] in
                self?.cancelRecording()
            }
        )
        showFloatingWindow = true
    }

    /// Cancel recording without inserting any text (called when panel is closed)
    func cancelRecording() {
        if isRecording {
            realtimeSTTService?.stopListening()
            realtimeSTTService = nil
            isRecording = false

            // Stop duration timer
            durationTimer?.invalidate()
            durationTimer = nil
            recordingStartTime = nil

            // Stop system audio capture if active
            if systemAudioCaptureService.isCapturing {
                Task {
                    await systemAudioCaptureService.stopCapturing()
                }
            }
        }
        transcriptionState = .idle
        currentTranscription = ""
        floatingWindowManager.hideFloatingWindow()
        showFloatingWindow = false
    }

    private func hideWindowAndPaste(_ text: String) {
        // Apply text replacement rules
        let processedText = TextReplacementService.shared.applyReplacements(to: text)

        // Check if clipboard-only mode
        if floatingWindowManager.clipboardOnly {
            // Just copy to clipboard, no paste
            ClipboardService.shared.copyToClipboard(processedText)
            if closePanelAfterPaste {
                floatingWindowManager.hideFloatingWindow(skipActivation: false)
                showFloatingWindow = false
            }
            transcriptionState = .idle
            return
        }

        // Validate paste destination before proceeding
        let status = floatingWindowManager.validatePasteDestination()
        if status != .valid {
            // Destination is invalid - alert is shown by validatePasteDestination
            // Don't close the window, let user select a new destination
            return
        }

        // Activate the selected window before hiding
        let activated = floatingWindowManager.activateSelectedWindow()

        if closePanelAfterPaste {
            // Close panel and paste (original behavior)
            floatingWindowManager.hideFloatingWindow(skipActivation: activated)
            showFloatingWindow = false
            transcriptionState = .idle

            // Delay paste to allow window to close and focus to switch
            let delay = activated ? 0.4 : 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                ClipboardService.shared.copyAndPaste(processedText)
            }
        } else {
            // Keep panel open: paste and return focus to panel
            transcriptionState = .idle

            // Temporarily hide panel to allow paste
            floatingWindowManager.temporarilyHideWindow()

            // Delay paste to allow focus to switch
            let delay = activated ? 0.3 : 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                ClipboardService.shared.copyAndPaste(processedText)

                // Bring panel back after paste completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self?.floatingWindowManager.bringToFront()
                }
            }
        }
    }

    // MARK: - TTS Methods

    func toggleTTS() {
        if ttsState == .speaking || ttsState == .paused {
            stopTTS()
        } else {
            startTTS()
        }
    }

    func startTTS() {
        #if DEBUG
        print("TTS: startTTS called")
        #endif

        // Mutual exclusivity: close STT panel and cancel recording if active
        if showFloatingWindow || isRecording {
            cancelRecording()
        }

        // Get selected text from frontmost app asynchronously
        Task {
            let selectedText = await TextSelectionService.shared.getSelectedText()

            if let selectedText = selectedText, !selectedText.isEmpty {
                #if DEBUG
                print("TTS: Got selected text, length: \(selectedText.count), content: '\(selectedText.prefix(200))'")
                #endif
                startTTSWithText(selectedText)
            } else {
                #if DEBUG
                print("TTS: No selected text, showing manual input window")
                #endif
                // Show TTS window for manual input
                ttsText = ""
                ttsState = .idle
                showTTSFloatingWindow()
            }
        }
    }

    func startTTSWithText(_ text: String) {
        guard !text.isEmpty else {
            #if DEBUG
            print("TTS: Empty text, aborting")
            #endif
            return
        }

        #if DEBUG
        print("TTS: Starting with text length: \(text.count), provider: \(selectedTTSProvider.rawValue)")
        #endif

        // Mutual exclusivity: close STT panel and cancel recording if active
        if showFloatingWindow || isRecording {
            cancelRecording()
        }

        // Stop any existing TTS
        stopTTSPlayback()

        #if DEBUG
        print("TTS: Setting ttsText, current value length: \(ttsText.count), new value length: \(text.count)")
        print("TTS: New text content: '\(text.prefix(200))'")
        #endif
        ttsText = text
        ttsState = .loading

        // Always ensure window is shown and brought to front
        if !showTTSWindow || !floatingWindowManager.isVisible {
            showTTSFloatingWindow()
        } else {
            floatingWindowManager.bringToFront()
        }

        // Apply text replacement rules before speaking
        let processedText = TextReplacementService.shared.applyReplacements(to: text)

        // Start TTS playback
        ttsService = TTSFactory.makeService(for: selectedTTSProvider)
        ttsService?.delegate = self
        ttsService?.selectedVoice = selectedTTSVoice
        if !selectedTTSModel.isEmpty {
            ttsService?.selectedModel = selectedTTSModel
        }
        ttsService?.selectedSpeed = selectedTTSSpeed
        if !selectedTTSLanguage.isEmpty {
            ttsService?.selectedLanguage = selectedTTSLanguage
        }
        ttsService?.audioOutputDeviceUID = selectedAudioOutputDeviceUID

        Task {
            do {
                try await ttsService?.speak(text: processedText)
                ttsState = .speaking
                lastSynthesizedText = ttsText
            } catch {
                #if DEBUG
                print("TTS: Error occurred: \(error)")
                #endif
                ttsState = .error(error.localizedDescription)
            }
        }
    }

    func pauseResumeTTS() {
        guard let service = ttsService else { return }
        if service.isPaused {
            service.resume()
            ttsState = .speaking
        } else if service.isSpeaking {
            service.pause()
            ttsState = .paused
        }
    }

    /// Stop TTS playback without resetting UI state (used internally)
    private func stopTTSPlayback() {
        ttsService?.stop()
        ttsService?.clearAudioCache()
        ttsService = nil
    }

    func stopTTS() {
        stopTTSPlayback()
        ttsState = .idle
        lastSynthesizedText = ""  // Clear cache reference

        // Ensure window state flag is in sync (in case stopTTS is called directly)
        if showTTSWindow && !floatingWindowManager.isVisible {
            showTTSWindow = false
        }
    }

    /// Check if TTS audio save is available (text >= 5 chars)
    func canSaveTTSAudio(for text: String) -> Bool {
        text.count >= 5
    }

    /// Get the file extension for TTS audio
    var ttsAudioFileExtension: String {
        ttsService?.audioFileExtension ?? "mp3"
    }

    /// Synthesize and save TTS audio
    /// - Reuses existing audio data if text matches lastSynthesizedText
    /// - Otherwise synthesizes new audio before saving
    func synthesizeAndSaveTTSAudio(_ text: String) {
        guard text.count >= 5 else { return }

        // Check if we can reuse existing audio data
        if text == lastSynthesizedText, let audioData = ttsService?.lastAudioData {
            // Reuse existing audio
            showSavePanel(with: audioData)
            return
        }

        // Need to synthesize new audio
        isSavingAudio = true

        // Create a new TTS service for synthesis (don't disturb current playback state)
        let saveService = TTSFactory.makeService(for: selectedTTSProvider)
        saveService.selectedVoice = selectedTTSVoice
        if !selectedTTSModel.isEmpty {
            saveService.selectedModel = selectedTTSModel
        }
        saveService.selectedSpeed = selectedTTSSpeed
        if !selectedTTSLanguage.isEmpty {
            saveService.selectedLanguage = selectedTTSLanguage
        }

        Task {
            do {
                try await saveService.speak(text: text)
                // Stop playback immediately (we only wanted the audio data)
                saveService.stop()

                if let audioData = saveService.lastAudioData {
                    // Update cache
                    lastSynthesizedText = text
                    // Store audio data in main service for future reuse
                    ttsService = saveService
                    showSavePanel(with: audioData)
                } else {
                    ttsState = .error("Failed to generate audio")
                }
            } catch {
                ttsState = .error(error.localizedDescription)
            }
            isSavingAudio = false
        }
    }

    /// Show save panel with the given audio data
    private func showSavePanel(with audioData: Data) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.audio]
        savePanel.nameFieldStringValue = "tts_audio.\(ttsAudioFileExtension)"
        savePanel.title = "Save Audio"
        savePanel.message = "Choose a location to save the audio file"
        WindowLevelCoordinator.configureSavePanel(savePanel)

        // Activate app and bring panel to front
        NSApp.activate(ignoringOtherApps: true)

        savePanel.begin { [audioData] response in
            if response == .OK, let url = savePanel.url {
                do {
                    try audioData.write(to: url)
                } catch {
                    print("Failed to save audio: \(error)")
                }
            }
        }
    }

    private func showTTSFloatingWindow() {
        floatingWindowManager.showTTSFloatingWindow(
            appState: self,
            onClose: { [weak self] in
                self?.closeTTSWindow()
            }
        )
        showTTSWindow = true
    }

    private func closeTTSWindow() {
        stopTTS()
        floatingWindowManager.hideFloatingWindow()
        showTTSWindow = false
        ttsText = ""
    }

    // MARK: - Preferences

    private func loadPreferences() {
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }

        if let providerRaw = UserDefaults.standard.string(forKey: "selectedRealtimeProvider"),
           let provider = RealtimeSTTProvider(rawValue: providerRaw) {
            selectedRealtimeProvider = provider
        }

        if let sttModel = UserDefaults.standard.string(forKey: "selectedRealtimeSTTModel") {
            selectedRealtimeSTTModel = sttModel
        }

        if let providerRaw = UserDefaults.standard.string(forKey: "selectedProvider"),
           let provider = STTProvider(rawValue: providerRaw) {
            selectedProvider = provider
        }

        if let modelRaw = UserDefaults.standard.string(forKey: "selectedModel"),
           let model = STTModel(rawValue: modelRaw) {
            selectedModel = model
        }

        if let ttsProviderRaw = UserDefaults.standard.string(forKey: "selectedTTSProvider"),
           let ttsProvider = TTSProvider(rawValue: ttsProviderRaw) {
            selectedTTSProvider = ttsProvider
        }

        if let ttsVoice = UserDefaults.standard.string(forKey: "selectedTTSVoice") {
            selectedTTSVoice = ttsVoice
        }

        if let ttsModel = UserDefaults.standard.string(forKey: "selectedTTSModel") {
            selectedTTSModel = ttsModel
        }

        if UserDefaults.standard.object(forKey: "selectedTTSSpeed") != nil {
            selectedTTSSpeed = UserDefaults.standard.double(forKey: "selectedTTSSpeed")
        }

        if let sttLanguage = UserDefaults.standard.string(forKey: "selectedSTTLanguage") {
            selectedSTTLanguage = sttLanguage
        }

        if let ttsLanguage = UserDefaults.standard.string(forKey: "selectedTTSLanguage") {
            selectedTTSLanguage = ttsLanguage
        }

        if let audioInputUID = UserDefaults.standard.string(forKey: "selectedAudioInputDeviceUID") {
            selectedAudioInputDeviceUID = audioInputUID
        }

        if let audioOutputUID = UserDefaults.standard.string(forKey: "selectedAudioOutputDeviceUID") {
            selectedAudioOutputDeviceUID = audioOutputUID
        }

        // Load audio source type, but reset App Audio to Microphone on startup
        // App Audio is session-only because the target app may not be running on next launch
        if let audioSourceTypeRaw = UserDefaults.standard.string(forKey: "selectedAudioInputSourceType"),
           let audioSourceType = AudioInputSourceType(rawValue: audioSourceTypeRaw) {
            // Reset App Audio to Microphone - App Audio is not persisted
            if audioSourceType == .applicationAudio {
                selectedAudioInputSourceType = .microphone
            } else {
                selectedAudioInputSourceType = audioSourceType
            }
        }

        // Note: selectedAudioAppBundleID is not loaded - it's session-only

        // VAD auto-stop settings
        if UserDefaults.standard.object(forKey: "vadMinimumRecordingTime") != nil {
            vadMinimumRecordingTime = UserDefaults.standard.double(forKey: "vadMinimumRecordingTime")
        }
        if UserDefaults.standard.object(forKey: "vadSilenceDuration") != nil {
            vadSilenceDuration = UserDefaults.standard.double(forKey: "vadSilenceDuration")
        }
        if UserDefaults.standard.object(forKey: "closePanelAfterPaste") != nil {
            closePanelAfterPaste = UserDefaults.standard.bool(forKey: "closePanelAfterPaste")
        }
        if UserDefaults.standard.object(forKey: "panelTextFontSize") != nil {
            panelTextFontSize = UserDefaults.standard.double(forKey: "panelTextFontSize")
        }

        // Validate providers: fall back to macOS if selected provider requires API key but it's not available
        validateSelectedProviders()
    }

    /// Validate that selected providers are available (have API keys if required)
    private func validateSelectedProviders() {
        // Validate STT provider
        if selectedRealtimeProvider.requiresAPIKey && !hasAPIKeyForSTT(selectedRealtimeProvider) {
            selectedRealtimeProvider = .macOS
        }

        // Validate TTS provider
        if selectedTTSProvider.requiresAPIKey && !hasAPIKeyForTTS(selectedTTSProvider) {
            selectedTTSProvider = .macOS
        }
    }

    private func hasAPIKeyForSTT(_ provider: RealtimeSTTProvider) -> Bool {
        switch provider {
        case .openAI:
            return apiKeyManager.hasAPIKey(for: .openAI)
        case .gemini:
            return apiKeyManager.hasAPIKey(for: .gemini)
        case .elevenLabs:
            return apiKeyManager.hasAPIKey(for: .elevenLabs)
        case .macOS, .localWhisper:
            return true
        }
    }

    private func hasAPIKeyForTTS(_ provider: TTSProvider) -> Bool {
        switch provider {
        case .openAI:
            return apiKeyManager.hasAPIKey(for: .openAI)
        case .gemini:
            return apiKeyManager.hasAPIKey(for: .gemini)
        case .elevenLabs:
            return apiKeyManager.hasAPIKey(for: .elevenLabs)
        case .macOS:
            return true
        }
    }

    private func savePreferences() {
        UserDefaults.standard.set(selectedRealtimeProvider.rawValue, forKey: "selectedRealtimeProvider")
        UserDefaults.standard.set(selectedRealtimeSTTModel, forKey: "selectedRealtimeSTTModel")
        UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider")
        UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedModel")
        UserDefaults.standard.set(selectedTTSProvider.rawValue, forKey: "selectedTTSProvider")
        UserDefaults.standard.set(selectedTTSVoice, forKey: "selectedTTSVoice")
        UserDefaults.standard.set(selectedTTSModel, forKey: "selectedTTSModel")
        UserDefaults.standard.set(selectedTTSSpeed, forKey: "selectedTTSSpeed")
        UserDefaults.standard.set(selectedSTTLanguage, forKey: "selectedSTTLanguage")
        UserDefaults.standard.set(selectedTTSLanguage, forKey: "selectedTTSLanguage")
        UserDefaults.standard.set(selectedAudioInputDeviceUID, forKey: "selectedAudioInputDeviceUID")
        UserDefaults.standard.set(selectedAudioOutputDeviceUID, forKey: "selectedAudioOutputDeviceUID")

        // Save audio source type, but don't persist App Audio (save as Microphone instead)
        // App Audio is session-only because the target app may not be running on next launch
        let sourceTypeToSave: AudioInputSourceType = selectedAudioInputSourceType == .applicationAudio
            ? .microphone
            : selectedAudioInputSourceType
        UserDefaults.standard.set(sourceTypeToSave.rawValue, forKey: "selectedAudioInputSourceType")

        // VAD auto-stop settings
        UserDefaults.standard.set(vadMinimumRecordingTime, forKey: "vadMinimumRecordingTime")
        UserDefaults.standard.set(vadSilenceDuration, forKey: "vadSilenceDuration")

        // STT panel behavior
        UserDefaults.standard.set(closePanelAfterPaste, forKey: "closePanelAfterPaste")

        // Panel text appearance
        UserDefaults.standard.set(panelTextFontSize, forKey: "panelTextFontSize")

        // Note: selectedAudioAppBundleID is not saved - it's session-only
    }
}

// MARK: - HotKeyServiceDelegate

extension AppState: HotKeyServiceDelegate {
    nonisolated func hotKeyPressed() {
        Task { @MainActor in
            self.toggleRecording()
        }
    }

    nonisolated func ttsHotKeyPressed() {
        Task { @MainActor in
            self.toggleTTS()
        }
    }
}

// MARK: - RealtimeSTTDelegate

extension AppState: RealtimeSTTDelegate {
    func realtimeSTT(_ service: RealtimeSTTService, didReceivePartialResult text: String) {
        currentTranscription = text
        // Keep in recording state while receiving partial results
    }

    func realtimeSTT(_ service: RealtimeSTTService, didReceiveFinalResult text: String) {
        currentTranscription = text

        // For "record then transcribe" providers, update state when result arrives
        if transcriptionState == .processing {
            if !text.isEmpty {
                transcriptionState = .result(text)
            } else {
                transcriptionState = .idle
            }
            // Clean up the service
            realtimeSTTService = nil
        }
    }

    func realtimeSTT(_ service: RealtimeSTTService, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
        transcriptionState = .error(error.localizedDescription)
        // Clean up the service if it was in processing state
        realtimeSTTService = nil
    }

    func realtimeSTT(_ service: RealtimeSTTService, didChangeListeningState isListening: Bool) {
        // State is managed by start/stop methods
    }
}

// MARK: - TTSDelegate

extension AppState: TTSDelegate {
    func tts(_ service: TTSService, willSpeakRange range: NSRange, of text: String) {
        // Word highlighting removed - streaming mode doesn't provide timing info
    }

    func tts(_ service: TTSService, didFinishSpeaking successfully: Bool) {
        ttsState = .idle
    }

    func tts(_ service: TTSService, didFailWithError error: Error) {
        ttsState = .error(error.localizedDescription)
    }
}

// MARK: - SystemAudioCaptureDelegate

extension AppState: SystemAudioCaptureDelegate {
    func systemAudioCapture(_ capture: SystemAudioCaptureService, didCaptureAudioBuffer buffer: AVAudioPCMBuffer) {
        // Forward audio buffer to STT service
        realtimeSTTService?.processAudioBuffer(buffer)
    }

    func systemAudioCapture(_ capture: SystemAudioCaptureService, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
        transcriptionState = .error(error.localizedDescription)
    }
}
