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

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    private var lastTranscription = ""

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

        // Stop any existing session
        stopListening()

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw RealtimeSTTError.audioError("Failed to create recognition request")
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true

        // Setup audio engine only for microphone mode
        if audioSource == .microphone {
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
            }

            // Start audio engine
            audioEngine.prepare()
            try audioEngine.start()
        }
        // For external source, audio will be fed via processAudioBuffer()

        // Start recognition task
        lastTranscription = ""
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            Task { @MainActor in
                if let result = result {
                    let transcription = result.bestTranscription.formattedString

                    if result.isFinal {
                        self.delegate?.realtimeSTT(self, didReceiveFinalResult: transcription)
                        self.lastTranscription = transcription
                    } else {
                        // Only send if there's new content
                        if transcription != self.lastTranscription {
                            self.delegate?.realtimeSTT(self, didReceivePartialResult: transcription)
                            self.lastTranscription = transcription
                        }
                    }
                }

                if let error = error {
                    // Check if it's just end of speech (not an actual error)
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        // End of speech detected - this is normal
                        return
                    }
                    self.delegate?.realtimeSTT(self, didFailWithError: error)
                }
            }
        }

        isListening = true
        delegate?.realtimeSTT(self, didChangeListeningState: true)
    }

    /// Process audio buffer from external source
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioSource == .external, isListening else { return }
        recognitionRequest?.append(buffer)
    }

    func stopListening() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

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
