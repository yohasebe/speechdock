import Foundation
import Speech
import AVFoundation

/// macOS native speech recognition using SFSpeechRecognizer
@MainActor
final class MacOSRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = ""  // macOS uses system default
    var selectedLanguage: String = ""  // "" = Auto (uses system locale)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    // VAD auto-stop settings (not used by macOS native, but required by protocol)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 3.0

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    private var lastTranscription = ""

    // Audio level monitoring
    private let audioLevelMonitor = AudioLevelMonitor.shared

    // Session restart mechanism to work around Apple's ~1 minute limit
    private var sessionStartTime: Date?
    private var sessionRestartTimer: Timer?
    private let maxSessionDuration: TimeInterval = 50  // Restart before 60s limit
    private var accumulatedTranscription = ""  // Preserve text across restarts
    private var isRestarting = false

    // Task identifier to ignore callbacks from old/cancelled tasks
    private var currentTaskId: UUID?
    private var restartTimestamp: Date?

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    }

    /// Create speech recognizer with the appropriate locale
    private func createRecognizer() -> SFSpeechRecognizer? {
        if !selectedLanguage.isEmpty,
           let langCode = LanguageCode(rawValue: selectedLanguage),
           let localeId = langCode.toLocaleIdentifier() {
            return SFSpeechRecognizer(locale: Locale(identifier: localeId))
        }
        return SFSpeechRecognizer(locale: Locale.current)
    }

    func startListening() async throws {
        // Check authorization
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard authStatus == .authorized else {
            throw RealtimeSTTError.permissionDenied("Speech recognition permission denied")
        }

        // Create recognizer with selected language
        speechRecognizer = createRecognizer()

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw RealtimeSTTError.serviceUnavailable("Speech recognizer not available")
        }

        // Stop any existing session (but don't clear accumulated text if restarting)
        if !isRestarting {
            stopListening()
            accumulatedTranscription = ""
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw RealtimeSTTError.audioError("Failed to create recognition request")
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true

        // Setup audio engine only for microphone mode (and not during restart)
        if audioSource == .microphone && !isRestarting {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else {
                throw RealtimeSTTError.audioError("Failed to create audio engine")
            }

            // Set audio input device if specified
            if !audioInputDeviceUID.isEmpty,
               let device = AudioInputManager.shared.device(withUID: audioInputDeviceUID) {
                try AudioInputManager.shared.setInputDevice(device, for: audioEngine)
            }

            // Configure input node
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)

                // Update audio level monitor
                if let channelData = buffer.floatChannelData {
                    let frameLength = Int(buffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                    self?.audioLevelMonitor.updateLevel(from: samples)
                }
            }

            // Start audio engine
            audioEngine.prepare()
            try audioEngine.start()
        }
        // For external source, audio will be fed via processAudioBuffer()

        // Start recognition task with unique ID to track callbacks
        lastTranscription = ""
        let taskId = UUID()
        currentTaskId = taskId

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            Task { @MainActor in
                // Ignore callbacks from old/cancelled tasks
                guard self.currentTaskId == taskId else { return }

                // Skip processing if we're in the middle of restarting
                guard !self.isRestarting else { return }

                if let result = result {
                    let currentTranscription = result.bestTranscription.formattedString

                    // Combine accumulated transcription with current session's transcription
                    let fullTranscription: String
                    if self.accumulatedTranscription.isEmpty {
                        fullTranscription = currentTranscription
                    } else if currentTranscription.isEmpty {
                        fullTranscription = self.accumulatedTranscription
                    } else {
                        fullTranscription = self.accumulatedTranscription + " " + currentTranscription
                    }

                    if result.isFinal {
                        self.delegate?.realtimeSTT(self, didReceiveFinalResult: fullTranscription)
                        self.lastTranscription = currentTranscription
                    } else {
                        // Only send if there's new content
                        if currentTranscription != self.lastTranscription {
                            self.delegate?.realtimeSTT(self, didReceivePartialResult: fullTranscription)
                            self.lastTranscription = currentTranscription
                        }
                    }
                }

                if let error = error {
                    // Ignore errors that occur shortly after restart (likely from old task)
                    if let restartTime = self.restartTimestamp,
                       Date().timeIntervalSince(restartTime) < 1.0 {
                        return
                    }

                    // Check if it's just end of speech or cancellation (not actual errors)
                    let nsError = error as NSError
                    // 1110: End of speech detected
                    // 216: Task was cancelled
                    // 209: Recognition request was invalidated
                    // 203: Recognition request was aborted
                    let ignoredCodes = [1110, 216, 209, 203, 301, 1101]
                    if nsError.domain == "kAFAssistantErrorDomain" && ignoredCodes.contains(nsError.code) {
                        return
                    }

                    // Also ignore if task state indicates cancellation
                    if self.recognitionTask?.state == .canceling || self.recognitionTask?.state == .completed {
                        return
                    }

                    self.delegate?.realtimeSTT(self, didFailWithError: error)
                }
            }
        }

        isListening = true

        // Start session timer for automatic restart (only on initial start, not restart)
        if !isRestarting {
            audioLevelMonitor.start()
            sessionStartTime = Date()
            startSessionRestartTimer()
            delegate?.realtimeSTT(self, didChangeListeningState: true)
        }

        isRestarting = false
    }

    /// Start timer to automatically restart recognition session before Apple's limit
    private func startSessionRestartTimer() {
        sessionRestartTimer?.invalidate()
        sessionRestartTimer = Timer.scheduledTimer(withTimeInterval: maxSessionDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartRecognitionSession()
            }
        }
    }

    /// Restart recognition session to avoid Apple's ~1 minute limit
    private func restartRecognitionSession() {
        guard isListening, !isRestarting else { return }
        dprint("MacOSRealtimeSTT: Restarting session to avoid Apple's time limit")


        isRestarting = true
        restartTimestamp = Date()

        // Save current transcription to accumulated text
        if !lastTranscription.isEmpty {
            if accumulatedTranscription.isEmpty {
                accumulatedTranscription = lastTranscription
            } else {
                accumulatedTranscription += " " + lastTranscription
            }
        }

        // Keep references to old request/task for cleanup
        let oldRequest = recognitionRequest
        let oldTask = recognitionTask

        // Create new recognition request BEFORE ending old one (for audio buffer continuity)
        // The audio tap will start sending to the new request immediately
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        recognitionRequest?.addsPunctuation = true

        // Now safely end the old request/task
        oldRequest?.endAudio()
        oldTask?.cancel()

        // Restart recognition with new request
        Task {
            do {
                try await startListeningWithExistingRequest()
            } catch {
                dprint("MacOSRealtimeSTT: Failed to restart session: \(error)")

                isRestarting = false
                delegate?.realtimeSTT(self, didFailWithError: error)
            }
        }
    }

    /// Start listening using the already-created recognition request (for seamless restart)
    private func startListeningWithExistingRequest() async throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw RealtimeSTTError.serviceUnavailable("Speech recognizer not available")
        }

        guard let recognitionRequest = recognitionRequest else {
            throw RealtimeSTTError.audioError("Recognition request not available")
        }

        // Start recognition task with unique ID
        lastTranscription = ""
        let taskId = UUID()
        currentTaskId = taskId

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            Task { @MainActor in
                // Ignore callbacks from old/cancelled tasks
                guard self.currentTaskId == taskId else { return }

                // Skip processing if we're in the middle of restarting
                guard !self.isRestarting else { return }

                if let result = result {
                    let currentTranscription = result.bestTranscription.formattedString

                    // Combine accumulated transcription with current session's transcription
                    let fullTranscription: String
                    if self.accumulatedTranscription.isEmpty {
                        fullTranscription = currentTranscription
                    } else if currentTranscription.isEmpty {
                        fullTranscription = self.accumulatedTranscription
                    } else {
                        fullTranscription = self.accumulatedTranscription + " " + currentTranscription
                    }

                    if result.isFinal {
                        self.delegate?.realtimeSTT(self, didReceiveFinalResult: fullTranscription)
                        self.lastTranscription = currentTranscription
                    } else {
                        if currentTranscription != self.lastTranscription {
                            self.delegate?.realtimeSTT(self, didReceivePartialResult: fullTranscription)
                            self.lastTranscription = currentTranscription
                        }
                    }
                }

                if let error = error {
                    // Ignore errors shortly after restart
                    if let restartTime = self.restartTimestamp,
                       Date().timeIntervalSince(restartTime) < 1.0 {
                        return
                    }

                    let nsError = error as NSError
                    let ignoredCodes = [1110, 216, 209, 203, 301, 1101]
                    if nsError.domain == "kAFAssistantErrorDomain" && ignoredCodes.contains(nsError.code) {
                        return
                    }

                    if self.recognitionTask?.state == .canceling || self.recognitionTask?.state == .completed {
                        return
                    }

                    self.delegate?.realtimeSTT(self, didFailWithError: error)
                }
            }
        }

        // Restart the session timer
        startSessionRestartTimer()

        isRestarting = false
    }

    /// Process audio buffer from external source
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioSource == .external, isListening else { return }
        recognitionRequest?.append(buffer)

        // Update audio level monitor
        if let channelData = buffer.floatChannelData {
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            audioLevelMonitor.updateLevel(from: samples)
        }
    }

    func stopListening() {
        // Stop session restart timer
        sessionRestartTimer?.invalidate()
        sessionRestartTimer = nil
        sessionStartTime = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioLevelMonitor.stop()

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        // Reset all state
        accumulatedTranscription = ""
        isRestarting = false
        currentTaskId = nil
        restartTimestamp = nil

        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [RealtimeSTTModelInfo(id: "default", name: "System Default", description: "macOS built-in speech recognition", isDefault: true)]
    }
}

enum RealtimeSTTError: LocalizedError {
    case permissionDenied(String)
    case serviceUnavailable(String)
    case audioError(String)
    case connectionError(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg): return "Permission denied: \(msg)"
        case .serviceUnavailable(let msg): return "Service unavailable: \(msg)"
        case .audioError(let msg): return "Audio error: \(msg)"
        case .connectionError(let msg): return "Connection error: \(msg)"
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
