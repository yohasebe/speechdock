import SwiftUI
import Combine
import AVFoundation
import ApplicationServices

#if compiler(>=6.1)
import Translation
#endif

enum TranscriptionState: Equatable {
    case idle
    case preparing  // Starting up audio capture and connection
    case recording
    case transcribingFile  // Transcribing an audio file
    case processing
    case result(String)
    case error(String)

    var statusText: String {
        switch self {
        case .idle: return ""
        case .preparing: return "Starting..."
        case .recording: return "Recording..."
        case .transcribingFile: return "Transcribing file..."
        case .processing: return "Processing..."
        case .result: return ""
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Panel window style for STT/TTS panels
enum PanelStyle: String, CaseIterable {
    case floating = "floating"
    case standardWindow = "standardWindow"

    var displayName: String {
        switch self {
        case .floating: return "Floating"
        case .standardWindow: return "Standard Window"
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
    /// Current session's transcription text (from STT service, for subtitle display only)
    private var currentSessionTranscription: String = ""
    /// Text to display in subtitle (only text from current recording session)
    var subtitleText: String {
        return currentSessionTranscription
    }
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

    // MARK: - Translation State
    var translationState: TranslationState = .idle
    var translationProvider: TranslationProvider = .macOS {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    var translationTargetLanguage: LanguageCode = .japanese {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }
    /// Original text before translation (for reverting)
    var originalTextBeforeTranslation: String = ""
    /// Saved TTS language before translation (for restoring when reverting)
    var savedTTSLanguageBeforeTranslation: String?
    private var translationTask: Task<Void, Never>?
    private var translationService: TranslationServiceProtocol?

    /// Language availability cache for macOS Translation (0=unsupported, 1=needs download, 2=installed)
    var macOSTranslationLanguageCache: [LanguageCode: Int] = [:]
    var hasCachedMacOSTranslationLanguages = false
    private var isCheckingLanguageAvailability = false

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

    /// Default font size for panel text areas
    static let defaultPanelTextFontSize: Double = 13.0
    /// Minimum font size for panel text areas
    static let minPanelTextFontSize: Double = 10.0
    /// Maximum font size for panel text areas
    static let maxPanelTextFontSize: Double = 24.0
    /// Font size step for increase/decrease
    static let panelTextFontSizeStep: Double = 1.0

    /// Increase panel text font size
    func increasePanelTextFontSize() {
        let newSize = min(panelTextFontSize + Self.panelTextFontSizeStep, Self.maxPanelTextFontSize)
        if newSize != panelTextFontSize {
            panelTextFontSize = newSize
        }
    }

    /// Decrease panel text font size
    func decreasePanelTextFontSize() {
        let newSize = max(panelTextFontSize - Self.panelTextFontSizeStep, Self.minPanelTextFontSize)
        if newSize != panelTextFontSize {
            panelTextFontSize = newSize
        }
    }

    /// Reset panel text font size to default
    func resetPanelTextFontSize() {
        if panelTextFontSize != Self.defaultPanelTextFontSize {
            panelTextFontSize = Self.defaultPanelTextFontSize
        }
    }

    // MARK: - Auto-Start Settings
    /// Whether to automatically start recording when STT panel opens (default: false = wait for user action)
    var sttAutoStart: Bool = false {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Whether to automatically start speaking when TTS panel opens with text (default: false = wait for user action)
    var ttsAutoSpeak: Bool = false {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Panel window style (floating or standard window)
    var panelStyle: PanelStyle = .floating {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    // MARK: - Subtitle Mode Settings
    /// Whether subtitle mode is enabled
    var subtitleModeEnabled: Bool = false {
        didSet {
            guard !isLoadingPreferences else { return }
            updateSubtitleOverlay()
            savePreferences()
        }
    }

    /// Subtitle overlay position (top or bottom)
    var subtitlePosition: SubtitlePosition = .bottom {
        didSet {
            guard !isLoadingPreferences else { return }
            // Clear custom position when user explicitly changes position setting
            if subtitleUseCustomPosition {
                subtitleUseCustomPosition = false
            } else {
                SubtitleOverlayManager.shared.updatePosition()
            }
            savePreferences()
        }
    }

    /// Subtitle font size (18-48pt)
    var subtitleFontSize: Double = 28.0 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Subtitle text opacity (0.0-1.0)
    var subtitleOpacity: Double = 0.85 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Subtitle background opacity (0.0-1.0)
    var subtitleBackgroundOpacity: Double = 0.5 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Maximum number of lines to display (2-6)
    var subtitleMaxLines: Int = 3 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Whether to hide STT panel when subtitle mode is active
    var subtitleHidePanelWhenActive: Bool = true {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Whether to use custom position instead of preset top/bottom
    var subtitleUseCustomPosition: Bool = false {
        didSet {
            guard !isLoadingPreferences else { return }
            // Only update position if not during drag and not being set by manager
            if !SubtitleOverlayManager.shared.isDragging {
                SubtitleOverlayManager.shared.updatePosition()
            }
            savePreferences()
        }
    }

    /// Set custom position flag without triggering updatePosition
    /// Used by SubtitleOverlayManager during drag operations
    func setCustomPositionFlag(_ value: Bool) {
        guard subtitleUseCustomPosition != value else { return }
        // Temporarily prevent the didSet from calling updatePosition
        let wasLoading = isLoadingPreferences
        isLoadingPreferences = true
        subtitleUseCustomPosition = value
        isLoadingPreferences = wasLoading
        savePreferences()
    }

    /// Custom X position for subtitle overlay
    var subtitleCustomX: Double = 0 {
        didSet {
            guard !isLoadingPreferences else { return }
            savePreferences()
        }
    }

    /// Custom Y position for subtitle overlay
    var subtitleCustomY: Double = 0 {
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

    // MARK: - OCR
    let ocrCoordinator = OCRCoordinator()

    // Expose hotKeyService for settings UI
    private(set) var hotKeyService: HotKeyService?
    private var realtimeSTTService: RealtimeSTTService?
    private var isLoadingPreferences = false  // Flag to prevent saving during load
    private var ttsService: TTSService?
    private var fileTranscriptionTask: Task<Void, Never>?

    private init() {
        loadPreferences()
        refreshVoiceCachesInBackground()
        prefetchAvailableAppsInBackground()
        updatePermissionStatus()
        setupOCRCallbacks()
        // Pre-cache macOS Translation language availability
        checkMacOSTranslationLanguageAvailability()
    }

    private func setupOCRCallbacks() {
        ocrCoordinator.onTextRecognized = { [weak self] text in
            guard let self = self else { return }
            // Show recognized text in TTS panel without auto-speaking
            // OCR results often need correction, so we always wait for user action
            self.showTTSPanelWithText(text)
        }

        ocrCoordinator.onError = { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                #if DEBUG
                print("OCR Error: \(error.localizedDescription)")
                #endif
                self.errorMessage = error.localizedDescription
            }
            // nil error indicates cancellation - no action needed
        }
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
            // If panel is already showing, start recording
            // If panel is not showing, show it first (and optionally start recording based on setting)
            if showFloatingWindow {
                startRecording()
            } else {
                showSTTPanel()
            }
        }
    }

    // MARK: - Subtitle Mode

    /// Toggle subtitle mode on/off
    func toggleSubtitleMode() {
        subtitleModeEnabled.toggle()
    }

    /// Update subtitle overlay visibility based on current state
    private func updateSubtitleOverlay() {
        if subtitleModeEnabled && isRecording {
            SubtitleOverlayManager.shared.show(appState: self)
            // Optionally hide STT panel
            if subtitleHidePanelWhenActive {
                floatingWindowManager.temporarilyHideWindow()
            }
        } else {
            SubtitleOverlayManager.shared.hide()
            // Show STT panel again if it was hidden
            if subtitleHidePanelWhenActive && showFloatingWindow {
                floatingWindowManager.bringToFront()
            }
        }
    }

    /// Show STT panel without starting recording (user can then click record button)
    private func showSTTPanel() {
        guard !isProcessing else { return }

        // Mutual exclusivity: close TTS panel and stop TTS if active
        if showTTSWindow || ttsState == .speaking || ttsState == .paused || ttsState == .loading {
            stopTTS()
            floatingWindowManager.hideFloatingWindow()
            showTTSWindow = false
            ttsText = ""
        }

        // Sync translation provider based on STT provider
        syncTranslationProviderForSTT()

        errorMessage = nil
        currentTranscription = ""
        currentSessionTranscription = ""
        transcriptionState = .idle

        // Show the panel
        showFloatingWindowWithState()

        // Auto-start recording if setting is enabled
        if sttAutoStart {
            startRecording()
        }
    }

    /// Start recording (can be called from panel button or auto-start)
    func startRecording() {
        guard !isProcessing && !isRecording && transcriptionState != .preparing else { return }

        // Mutual exclusivity: close TTS panel and stop TTS if active
        if showTTSWindow || ttsState == .speaking || ttsState == .paused || ttsState == .loading {
            stopTTS()
            floatingWindowManager.hideFloatingWindow()
            showTTSWindow = false
            ttsText = ""
        }

        // Sync translation provider based on STT provider (when called directly without showSTTPanel)
        syncTranslationProviderForSTT()

        // Reset translation state if showing translated text
        if translationState.isTranslated {
            translationState = .idle
            originalTextBeforeTranslation = ""
            savedTTSLanguageBeforeTranslation = nil
        }

        // Reset session transcription for subtitle display
        currentSessionTranscription = ""

        errorMessage = nil

        // IMMEDIATELY show preparing state for instant user feedback
        transcriptionState = .preparing

        // Show floating window immediately so user sees "Starting..."
        if !showFloatingWindow {
            showFloatingWindowWithState()
        }

        // Start realtime STT (audio capture and connection)
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

                // Show subtitle overlay if enabled
                if subtitleModeEnabled {
                    SubtitleOverlayManager.shared.show(appState: self)
                    if subtitleHidePanelWhenActive {
                        floatingWindowManager.temporarilyHideWindow()
                    }
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

        // All providers now use realtime streaming - immediate result
        realtimeSTTService?.stopListening()
        realtimeSTTService = nil

        // If we have transcription, show result state
        if !currentTranscription.isEmpty {
            transcriptionState = .result(currentTranscription)
        } else {
            transcriptionState = .idle
        }

        // Stop system audio capture if active
        if systemAudioCaptureService.isCapturing {
            Task {
                await systemAudioCaptureService.stopCapturing()
            }
        }

        // Hide subtitle overlay and restore panel (deferred to avoid blocking)
        let shouldRestorePanel = subtitleHidePanelWhenActive && showFloatingWindow
        Task { @MainActor in
            SubtitleOverlayManager.shared.hide()
            if shouldRestorePanel {
                // Small delay to let UI settle before bringing panel back
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                floatingWindowManager.bringToFront()
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

        // Hide subtitle overlay asynchronously
        Task { @MainActor in
            SubtitleOverlayManager.shared.hide()
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

            // Hide subtitle overlay asynchronously
            Task { @MainActor in
                SubtitleOverlayManager.shared.hide()
            }

            // Stop system audio capture if active
            if systemAudioCaptureService.isCapturing {
                Task {
                    await systemAudioCaptureService.stopCapturing()
                }
            }
        }
        transcriptionState = .idle
        currentTranscription = ""
        currentSessionTranscription = ""
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
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await ClipboardService.shared.copyAndPaste(processedText)
            }
        } else {
            // Keep panel open: paste and return focus to panel
            transcriptionState = .idle

            // Temporarily hide panel to allow paste
            floatingWindowManager.temporarilyHideWindow()

            // Delay paste to allow focus to switch
            let delay = activated ? 0.3 : 0.2
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await ClipboardService.shared.copyAndPaste(processedText)

                // Bring panel back after paste completes
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                await MainActor.run {
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

    /// Show TTS panel with text, respecting auto-speak setting
    func startTTSWithText(_ text: String) {
        guard !text.isEmpty else { return }

        // Show panel with text
        showTTSPanelWithText(text)

        // Auto-speak if setting is enabled
        if ttsAutoSpeak {
            speakCurrentText()
        }
    }

    /// Show TTS panel with text without speaking (user can click Speak button)
    func showTTSPanelWithText(_ text: String) {
        guard !text.isEmpty else { return }

        #if DEBUG
        print("TTS: showTTSPanelWithText, text length: \(text.count)")
        #endif

        // Mutual exclusivity: close STT panel and cancel recording if active
        if showFloatingWindow || isRecording {
            cancelRecording()
        }

        // Stop any existing TTS
        stopTTSPlayback()

        ttsText = text
        ttsState = .idle

        // Always ensure window is shown and brought to front
        if !showTTSWindow || !floatingWindowManager.isVisible {
            showTTSFloatingWindow()
        } else {
            floatingWindowManager.bringToFront()
        }
    }

    /// Speak the current ttsText (can be called from panel button)
    func speakCurrentText() {
        guard !ttsText.isEmpty else { return }

        #if DEBUG
        print("TTS: speakCurrentText, text length: \(ttsText.count), provider: \(selectedTTSProvider.rawValue)")
        #endif

        ttsState = .loading

        // Apply text replacement rules before speaking
        let processedText = TextReplacementService.shared.applyReplacements(to: ttsText)

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

        // Store the text being spoken
        lastSynthesizedText = ttsText

        Task {
            do {
                // speak() will call delegate.ttsDidStartSpeaking() when playback starts
                // and delegate.tts(didFinishSpeaking:) when it completes
                try await ttsService?.speak(text: processedText)
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

    /// Set TTS playback rate dynamically during playback (0.25 to 4.0)
    func setTTSPlaybackRate(_ rate: Float) {
        ttsService?.setPlaybackRate(rate)
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

    /// Task for save audio operation (to allow cancellation)
    private var saveAudioTask: Task<Void, Never>?

    /// Synthesize and save TTS audio
    /// - Reuses existing audio data if text matches lastSynthesizedText and audio is complete
    /// - Otherwise synthesizes new audio using non-streaming mode before saving
    func synthesizeAndSaveTTSAudio(_ text: String) {
        guard text.count >= 5 else { return }

        // Check if we can reuse existing audio data (must be complete, not partial streaming data)
        if text == lastSynthesizedText,
           let audioData = ttsService?.lastAudioData,
           !audioData.isEmpty {
            // Reuse existing audio - show save panel directly (no loading state needed)
            showSavePanel(with: audioData, fileExtension: ttsAudioFileExtension)
            return
        }

        // Cancel any existing save task
        saveAudioTask?.cancel()

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

        // IMPORTANT: Use non-streaming mode for save operations
        // This ensures audio is fully generated before playback starts,
        // allowing us to stop playback and get complete audio data
        saveService.useStreamingMode = false

        // Capture file extension before Task (MainActor isolated)
        let fileExtension = saveService.audioFileExtension

        saveAudioTask = Task { @MainActor in
            defer {
                // Clean up
                saveService.stop()
                saveService.clearAudioCache()
            }

            do {
                // Apply text replacement rules before synthesis
                let processedText = TextReplacementService.shared.applyReplacements(to: text)

                // Synthesize audio (this will start playback, but we'll stop it immediately)
                try await saveService.speak(text: processedText)

                // Check if cancelled
                if Task.isCancelled {
                    self.isSavingAudio = false
                    return
                }

                // Stop playback immediately - we only want the audio data, not playback
                saveService.stop()

                // Check if TTS window is still open before showing save panel
                guard self.showTTSWindow else {
                    self.isSavingAudio = false
                    return
                }

                // Get the audio data
                if let audioData = saveService.lastAudioData, !audioData.isEmpty {
                    // Update cache for potential reuse
                    self.lastSynthesizedText = text
                    self.isSavingAudio = false
                    self.showSavePanel(with: audioData, fileExtension: fileExtension)
                } else {
                    self.isSavingAudio = false
                    self.ttsState = .error("Failed to generate audio")
                }
            } catch {
                if !Task.isCancelled {
                    self.isSavingAudio = false
                    self.ttsState = .error(error.localizedDescription)
                } else {
                    self.isSavingAudio = false
                }
            }
        }
    }

    /// Cancel any ongoing save audio operation
    func cancelSaveAudio() {
        saveAudioTask?.cancel()
        saveAudioTask = nil
        isSavingAudio = false
    }

    /// Show save panel with the given audio data
    private func showSavePanel(with audioData: Data, fileExtension: String) {
        // Dispatch to next run loop to avoid any blocking issues
        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.audio]
            savePanel.nameFieldStringValue = "tts_audio.\(fileExtension)"
            savePanel.title = "Save Audio"
            savePanel.message = "Choose a location to save the audio file"

            // Configure save panel to appear above all floating panels
            WindowLevelCoordinator.configureSavePanel(savePanel)

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    do {
                        try audioData.write(to: url)
                        #if DEBUG
                        print("Audio saved to: \(url.path)")
                        #endif
                    } catch {
                        #if DEBUG
                        print("Failed to save audio: \(error)")
                        #endif
                    }
                }
            }
        }
    }

    private func showTTSFloatingWindow() {
        // Sync translation provider based on TTS provider
        syncTranslationProviderForTTS()

        floatingWindowManager.showTTSFloatingWindow(
            appState: self,
            onClose: { [weak self] in
                self?.closeTTSWindow()
            }
        )
        showTTSWindow = true
    }

    private func closeTTSWindow() {
        // Cancel any ongoing save operation
        cancelSaveAudio()
        stopTTS()
        floatingWindowManager.hideFloatingWindow()
        showTTSWindow = false
        ttsText = ""
    }

    // MARK: - OCR Methods

    /// Start OCR region selection
    func startOCR() {
        // Close any open STT or TTS panels first
        if showFloatingWindow || isRecording {
            cancelRecording()
        }
        if showTTSWindow || ttsState == .speaking || ttsState == .paused || ttsState == .loading {
            closeTTSWindow()
        }

        // Start OCR selection
        ocrCoordinator.startSelection()
    }

    /// Cancel OCR operation
    func cancelOCR() {
        ocrCoordinator.cancel()
    }

    // MARK: - Translation Provider Sync

    /// Sync translation provider based on STT provider when STT panel opens
    private func syncTranslationProviderForSTT() {
        switch selectedRealtimeProvider {
        case .openAI:
            if translationProvider != .openAI {
                translationProvider = .openAI
            }
        case .gemini:
            if translationProvider != .gemini {
                translationProvider = .gemini
            }
        case .elevenLabs, .grok, .macOS:
            // ElevenLabs/Grok/macOS don't have corresponding translation providers, use macOS
            if translationProvider != .macOS {
                translationProvider = .macOS
            }
        }
    }

    /// Sync translation provider based on TTS provider when TTS panel opens
    private func syncTranslationProviderForTTS() {
        switch selectedTTSProvider {
        case .openAI:
            if translationProvider != .openAI {
                translationProvider = .openAI
            }
        case .gemini:
            if translationProvider != .gemini {
                translationProvider = .gemini
            }
        case .elevenLabs, .grok, .macOS:
            // ElevenLabs/Grok/macOS don't have corresponding translation providers, use macOS
            if translationProvider != .macOS {
                translationProvider = .macOS
            }
        }
    }

    // MARK: - Translation Methods

    /// Translate text to target language
    /// - Parameters:
    ///   - text: Text to translate
    ///   - targetLanguage: Target language
    ///   - sourceLanguage: Source language (nil for auto-detect)
    func translateText(_ text: String, to targetLanguage: LanguageCode, from sourceLanguage: LanguageCode? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            #if DEBUG
            print("Translation: Empty text, skipping")
            #endif
            return
        }
        guard translationState != .translating else {
            #if DEBUG
            print("Translation: Already translating, skipping")
            #endif
            return
        }

        #if DEBUG
        print("Translation: Starting translation to \(targetLanguage.displayName)")
        print("Translation: Text length = \(text.count)")
        #endif

        // Save original text and TTS language for reverting
        originalTextBeforeTranslation = text
        savedTTSLanguageBeforeTranslation = selectedTTSLanguage

        // Determine best provider
        let provider = TranslationFactory.bestAvailableProvider(
            for: targetLanguage,
            preferredProvider: translationProvider
        )

        #if DEBUG
        print("Translation: Using provider = \(provider.displayName)")
        #endif

        translationState = .translating
        translationService = TranslationFactory.makeService(for: provider)

        translationTask = Task { @MainActor in
            do {
                #if DEBUG
                print("Translation: Calling translate API...")
                #endif

                let result = try await translationService?.translate(
                    text: text,
                    to: targetLanguage,
                    from: sourceLanguage
                )

                if Task.isCancelled {
                    #if DEBUG
                    print("Translation: Task was cancelled")
                    #endif
                    translationState = .idle
                    return
                }

                if let result = result {
                    #if DEBUG
                    print("Translation: Success! Result length = \(result.translatedText.count)")
                    print("Translation: Result = \(result.translatedText.prefix(100))...")
                    #endif
                    translationState = .translated(result.translatedText)
                    translationTargetLanguage = targetLanguage

                    // Update TTS language to match translation target for seamless TTS
                    selectedTTSLanguage = targetLanguage.rawValue
                } else {
                    #if DEBUG
                    print("Translation: No result returned")
                    #endif
                    translationState = .error("Translation returned no result")
                }
            } catch {
                #if DEBUG
                print("Translation: Error = \(error.localizedDescription)")
                #endif
                if !Task.isCancelled {
                    translationState = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Cancel ongoing translation
    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        translationService?.cancel()
        translationService = nil
        translationState = .idle
    }

    /// Revert to original text before translation
    func revertToOriginalText() {
        guard translationState.isTranslated else { return }

        translationState = .idle

        // Restore TTS language
        if let savedLanguage = savedTTSLanguageBeforeTranslation {
            selectedTTSLanguage = savedLanguage
        }
        savedTTSLanguageBeforeTranslation = nil
    }

    /// Check if translation is available for a given language
    func isTranslationAvailable(to targetLanguage: LanguageCode) async -> Bool {
        let provider = TranslationFactory.bestAvailableProvider(
            for: targetLanguage,
            preferredProvider: translationProvider
        )
        let service = TranslationFactory.makeService(for: provider)
        return await service.isAvailable(from: nil, to: targetLanguage)
    }

    /// Check macOS Translation language availability and cache results
    func checkMacOSTranslationLanguageAvailability() {
        #if compiler(>=6.1)
        guard !isCheckingLanguageAvailability else { return }
        isCheckingLanguageAvailability = true

        Task { @MainActor in
            if #available(macOS 15.0, *) {
                let availability = LanguageAvailability()
                // Check from both Japanese and English to cover common use cases
                let sourceLocales = [
                    Locale.Language(identifier: "ja"),
                    Locale.Language(identifier: "en")
                ]
                let allLanguages = LanguageCode.allCases.filter { $0 != .auto }

                for language in allLanguages {
                    guard let targetLocale = language.toLocaleLanguage() else { continue }

                    // Check availability from multiple sources and take the best result
                    var bestStatus: Int = 0  // 0 = unsupported
                    for sourceLocale in sourceLocales {
                        // Skip same language pair
                        if sourceLocale.languageCode == targetLocale.languageCode {
                            continue
                        }

                        let status = await availability.status(from: sourceLocale, to: targetLocale)
                        let statusInt: Int
                        switch status {
                        case .installed:
                            statusInt = 2
                        case .supported:
                            statusInt = 1
                        case .unsupported:
                            statusInt = 0
                        @unknown default:
                            statusInt = 0
                        }

                        // Keep the best status (installed > supported > unsupported)
                        if statusInt > bestStatus {
                            bestStatus = statusInt
                        }
                    }

                    macOSTranslationLanguageCache[language] = bestStatus
                }
            }
            hasCachedMacOSTranslationLanguages = true
            isCheckingLanguageAvailability = false

            #if DEBUG
            print("AppState: macOS Translation language availability cached")
            for (lang, status) in macOSTranslationLanguageCache.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("  \(lang.displayName): \(status == 2 ? "installed" : status == 1 ? "needs download" : "unsupported")")
            }
            #endif
        }
        #else
        // Translation framework not available on older SDKs
        hasCachedMacOSTranslationLanguages = true
        #endif
    }

    /// Refresh macOS Translation language availability cache
    func refreshMacOSTranslationLanguageAvailability() {
        macOSTranslationLanguageCache.removeAll()
        hasCachedMacOSTranslationLanguages = false
        checkMacOSTranslationLanguageAvailability()
    }

    // MARK: - File Transcription

    /// Show notification alert for file transcription issues
    private func showFileTranscriptionNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "File Transcription"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // Configure alert to appear above floating panels
        alert.window.level = .floating + 1

        alert.runModal()
    }

    /// Transcribe an audio file
    /// - Parameter url: URL of the audio file to transcribe
    func transcribeAudioFile(_ url: URL) {
        // Check if provider supports file transcription
        guard selectedRealtimeProvider.supportsFileTranscription else {
            showFileTranscriptionNotice("\(selectedRealtimeProvider.rawValue) does not support file transcription.\n\nPlease switch to OpenAI, Gemini, or ElevenLabs provider.")
            return
        }

        // Check if already recording or transcribing
        guard !isRecording && transcriptionState != .transcribingFile else {
            return
        }

        // Mutual exclusivity: close TTS panel if active
        if showTTSWindow || ttsState == .speaking || ttsState == .paused || ttsState == .loading {
            stopTTS()
            floatingWindowManager.hideFloatingWindow()
            showTTSWindow = false
            ttsText = ""
        }

        // Show STT panel if not already visible
        if !showFloatingWindow {
            errorMessage = nil
            currentTranscription = ""
            currentSessionTranscription = ""
            showFloatingWindowWithState()
        }

        // Start file transcription
        fileTranscriptionTask = Task { @MainActor in
            transcriptionState = .transcribingFile

            do {
                let result = try await FileTranscriptionService.shared.transcribe(
                    fileURL: url,
                    provider: selectedRealtimeProvider,
                    language: selectedSTTLanguage.isEmpty ? nil : selectedSTTLanguage
                )

                if !Task.isCancelled {
                    currentTranscription = result.text
                    transcriptionState = .result(result.text)
                }
            } catch {
                if !Task.isCancelled {
                    transcriptionState = .idle
                    showFileTranscriptionNotice(error.localizedDescription)
                }
            }
        }
    }

    /// Cancel ongoing file transcription
    func cancelFileTranscription() {
        fileTranscriptionTask?.cancel()
        fileTranscriptionTask = nil
        transcriptionState = .idle
    }

    /// Open file picker for audio file transcription
    func openAudioFileForTranscription() {
        // Check provider support first
        guard selectedRealtimeProvider.supportsFileTranscription else {
            showFileTranscriptionNotice("\(selectedRealtimeProvider.rawValue) does not support file transcription.\n\nPlease switch to OpenAI, Gemini, or ElevenLabs provider.")
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        // Build allowed content types safely
        var allowedTypes: [UTType] = [.mp3, .wav, .mpeg4Audio]
        let additionalExtensions = ["m4a", "aac", "webm", "ogg", "flac", "mp4"]
        for ext in additionalExtensions {
            if let type = UTType(filenameExtension: ext) {
                allowedTypes.append(type)
            }
        }
        openPanel.allowedContentTypes = allowedTypes

        openPanel.title = "Select Audio File"
        openPanel.message = "Choose an audio file to transcribe"

        // Configure panel to appear above floating panels
        WindowLevelCoordinator.configureSavePanel(openPanel)

        // Bring app to front
        NSApp.activate(ignoringOtherApps: true)

        openPanel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = openPanel.url {
                self.transcribeAudioFile(url)
            }
        }
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

        // Auto-start settings
        if UserDefaults.standard.object(forKey: "sttAutoStart") != nil {
            sttAutoStart = UserDefaults.standard.bool(forKey: "sttAutoStart")
        }
        if UserDefaults.standard.object(forKey: "ttsAutoSpeak") != nil {
            ttsAutoSpeak = UserDefaults.standard.bool(forKey: "ttsAutoSpeak")
        }

        // Panel style
        if let panelStyleRaw = UserDefaults.standard.string(forKey: "panelStyle"),
           let style = PanelStyle(rawValue: panelStyleRaw) {
            panelStyle = style
        }

        // Subtitle mode settings
        if UserDefaults.standard.object(forKey: "subtitleModeEnabled") != nil {
            subtitleModeEnabled = UserDefaults.standard.bool(forKey: "subtitleModeEnabled")
        }
        if let subtitlePositionRaw = UserDefaults.standard.string(forKey: "subtitlePosition"),
           let position = SubtitlePosition(rawValue: subtitlePositionRaw) {
            subtitlePosition = position
        }
        if UserDefaults.standard.object(forKey: "subtitleFontSize") != nil {
            subtitleFontSize = UserDefaults.standard.double(forKey: "subtitleFontSize")
        }
        if UserDefaults.standard.object(forKey: "subtitleOpacity") != nil {
            subtitleOpacity = UserDefaults.standard.double(forKey: "subtitleOpacity")
        }
        if UserDefaults.standard.object(forKey: "subtitleBackgroundOpacity") != nil {
            subtitleBackgroundOpacity = UserDefaults.standard.double(forKey: "subtitleBackgroundOpacity")
        }
        if UserDefaults.standard.object(forKey: "subtitleMaxLines") != nil {
            subtitleMaxLines = UserDefaults.standard.integer(forKey: "subtitleMaxLines")
        }
        if UserDefaults.standard.object(forKey: "subtitleHidePanelWhenActive") != nil {
            subtitleHidePanelWhenActive = UserDefaults.standard.bool(forKey: "subtitleHidePanelWhenActive")
        }
        if UserDefaults.standard.object(forKey: "subtitleUseCustomPosition") != nil {
            subtitleUseCustomPosition = UserDefaults.standard.bool(forKey: "subtitleUseCustomPosition")
        }
        if UserDefaults.standard.object(forKey: "subtitleCustomX") != nil {
            subtitleCustomX = UserDefaults.standard.double(forKey: "subtitleCustomX")
        }
        if UserDefaults.standard.object(forKey: "subtitleCustomY") != nil {
            subtitleCustomY = UserDefaults.standard.double(forKey: "subtitleCustomY")
        }

        // Translation settings
        if let translationProviderRaw = UserDefaults.standard.string(forKey: "translationProvider"),
           let provider = TranslationProvider(rawValue: translationProviderRaw) {
            translationProvider = provider
        }
        if let translationTargetRaw = UserDefaults.standard.string(forKey: "translationTargetLanguage"),
           let language = LanguageCode(rawValue: translationTargetRaw) {
            translationTargetLanguage = language
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
        case .grok:
            return apiKeyManager.hasAPIKey(for: .grok)
        case .macOS:
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
        case .grok:
            return apiKeyManager.hasAPIKey(for: .grok)
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

        // Auto-start settings
        UserDefaults.standard.set(sttAutoStart, forKey: "sttAutoStart")
        UserDefaults.standard.set(ttsAutoSpeak, forKey: "ttsAutoSpeak")

        // Panel style
        UserDefaults.standard.set(panelStyle.rawValue, forKey: "panelStyle")

        // Subtitle mode settings
        UserDefaults.standard.set(subtitleModeEnabled, forKey: "subtitleModeEnabled")
        UserDefaults.standard.set(subtitlePosition.rawValue, forKey: "subtitlePosition")
        UserDefaults.standard.set(subtitleFontSize, forKey: "subtitleFontSize")
        UserDefaults.standard.set(subtitleOpacity, forKey: "subtitleOpacity")
        UserDefaults.standard.set(subtitleBackgroundOpacity, forKey: "subtitleBackgroundOpacity")
        UserDefaults.standard.set(subtitleMaxLines, forKey: "subtitleMaxLines")
        UserDefaults.standard.set(subtitleHidePanelWhenActive, forKey: "subtitleHidePanelWhenActive")
        UserDefaults.standard.set(subtitleUseCustomPosition, forKey: "subtitleUseCustomPosition")
        UserDefaults.standard.set(subtitleCustomX, forKey: "subtitleCustomX")
        UserDefaults.standard.set(subtitleCustomY, forKey: "subtitleCustomY")

        // Translation settings
        UserDefaults.standard.set(translationProvider.rawValue, forKey: "translationProvider")
        UserDefaults.standard.set(translationTargetLanguage.rawValue, forKey: "translationTargetLanguage")

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

    nonisolated func ocrHotKeyPressed() {
        Task { @MainActor in
            self.startOCR()
        }
    }

    nonisolated func subtitleHotKeyPressed() {
        Task { @MainActor in
            self.toggleSubtitleMode()
        }
    }
}

// MARK: - RealtimeSTTDelegate

extension AppState: RealtimeSTTDelegate {
    func realtimeSTT(_ service: RealtimeSTTService, didReceivePartialResult text: String) {
        // Update current transcription (View handles accumulation)
        currentTranscription = text
        // Store session transcription for subtitle display (current session only)
        currentSessionTranscription = text
        // Keep in recording state while receiving partial results
    }

    func realtimeSTT(_ service: RealtimeSTTService, didReceiveFinalResult text: String) {
        // Update current transcription (View handles accumulation)
        currentTranscription = text
        // Store session transcription for subtitle display (current session only)
        currentSessionTranscription = text

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

    func ttsDidStartSpeaking(_ service: TTSService) {
        ttsState = .speaking
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
