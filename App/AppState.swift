import SwiftUI
import Combine

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
    var currentSpeakingRange: NSRange?
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

        isRecording = true
        errorMessage = nil
        transcriptionState = .recording
        currentTranscription = ""
        showFloatingWindowWithState()

        // Start realtime STT
        Task {
            await startRealtimeSTT()
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

        do {
            try await realtimeSTTService?.startListening()
        } catch {
            errorMessage = error.localizedDescription
            transcriptionState = .error(error.localizedDescription)
        }
    }

    private func stopRecording() {
        isRecording = false
        realtimeSTTService?.stopListening()
        realtimeSTTService = nil

        // If we have transcription, show result state
        if !currentTranscription.isEmpty {
            transcriptionState = .result(currentTranscription)
        } else {
            transcriptionState = .idle
        }
    }

    /// Stop recording and immediately insert the text
    func stopRecordingAndInsert(_ text: String) {
        // Stop recording first
        isRecording = false
        realtimeSTTService?.stopListening()
        realtimeSTTService = nil
        transcriptionState = .idle

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

    private func cancelRecording() {
        if isRecording {
            realtimeSTTService?.stopListening()
            realtimeSTTService = nil
            isRecording = false
        }
        transcriptionState = .idle
        currentTranscription = ""
        floatingWindowManager.hideFloatingWindow()
        showFloatingWindow = false
    }

    private func hideWindowAndPaste(_ text: String) {
        floatingWindowManager.hideFloatingWindow()
        showFloatingWindow = false
        transcriptionState = .idle

        // Delay paste to allow window to close and focus to return
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            ClipboardService.shared.copyAndPaste(text)
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
        print("TTS: startTTS called")

        // Get selected text from frontmost app
        // Note: This runs on main thread synchronously
        let selectedText = TextSelectionService.shared.getSelectedText()

        if let selectedText = selectedText, !selectedText.isEmpty {
            print("TTS: Got selected text, length: \(selectedText.count)")
            startTTSWithText(selectedText)
        } else {
            print("TTS: No selected text, showing manual input window")
            // Show TTS window for manual input
            ttsText = ""
            ttsState = .idle
            showTTSFloatingWindow()
        }
    }

    func startTTSWithText(_ text: String) {
        guard !text.isEmpty else {
            print("TTS: Empty text, aborting")
            return
        }

        print("TTS: Starting with text length: \(text.count), provider: \(selectedTTSProvider.rawValue)")

        // Stop any existing TTS but don't reset everything
        ttsService?.stop()
        ttsService = nil

        ttsText = text
        ttsState = .loading
        currentSpeakingRange = nil

        // Only show window if not already visible
        if !showTTSWindow {
            showTTSFloatingWindow()
        }

        // Create TTS service and start speaking
        print("TTS: Creating service...")
        ttsService = TTSFactory.makeService(for: selectedTTSProvider)
        ttsService?.delegate = self
        ttsService?.selectedVoice = selectedTTSVoice
        if !selectedTTSModel.isEmpty {
            ttsService?.selectedModel = selectedTTSModel
        }
        ttsService?.selectedSpeed = selectedTTSSpeed
        print("TTS: Service created, delegate set, voice: \(selectedTTSVoice), model: \(selectedTTSModel), speed: \(selectedTTSSpeed)")

        Task {
            do {
                print("TTS: Calling speak()...")
                try await ttsService?.speak(text: text)
                print("TTS: speak() returned, setting state to speaking")
                ttsState = .speaking
            } catch {
                print("TTS: Error occurred: \(error)")
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

    func stopTTS() {
        ttsService?.stop()
        ttsService = nil
        ttsState = .idle
        currentSpeakingRange = nil
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
        // Don't auto-stop on final result for continuous transcription
    }

    func realtimeSTT(_ service: RealtimeSTTService, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
        transcriptionState = .error(error.localizedDescription)
    }

    func realtimeSTT(_ service: RealtimeSTTService, didChangeListeningState isListening: Bool) {
        // State is managed by start/stop methods
    }
}

// MARK: - TTSDelegate

extension AppState: TTSDelegate {
    func tts(_ service: TTSService, willSpeakRange range: NSRange, of text: String) {
        currentSpeakingRange = range
    }

    func tts(_ service: TTSService, didFinishSpeaking successfully: Bool) {
        ttsState = .idle
        currentSpeakingRange = nil
    }

    func tts(_ service: TTSService, didFailWithError error: Error) {
        ttsState = .error(error.localizedDescription)
        currentSpeakingRange = nil
    }
}
