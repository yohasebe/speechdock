import Foundation
@preconcurrency import AVFoundation

/// Local WhisperKit-based speech-to-text (record then transcribe)
@MainActor
final class LocalWhisperSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = ""
    var selectedLanguage: String = ""  // "" = Auto
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    private var audioEngine: AVAudioEngine?

    // Audio buffer (no max limit - record until stop)
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()

    // VAD for auto-stop
    private let vadService = VADService.shared
    private var vadBuffer: [Float] = []
    private let vadChunkSize = 4096  // 256ms at 16kHz
    private var silenceStartTime: Date?
    private var recordingStartTime: Date?

    // VAD auto-stop settings (configurable via AppState)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 3.0

    // Audio level monitoring
    private let audioLevelMonitor = AudioLevelMonitor.shared

    private let whisperKitManager = WhisperKitManager.shared
    private let sampleRate: Double = 16000

    func startListening() async throws {
        // Check if model is available (don't block on loading here)
        guard whisperKitManager.whisperKit != nil else {
            throw RealtimeSTTError.apiError("WhisperKit model not loaded. Please download a model in Settings.")
        }

        // Stop any existing session
        stopListening()

        // Reset state
        bufferLock.lock()
        audioBuffer.removeAll()
        vadBuffer.removeAll()
        bufferLock.unlock()
        silenceStartTime = nil
        recordingStartTime = Date()
        vadService.reset()
        audioLevelMonitor.start()

        // Start audio capture FIRST for immediate response
        if audioSource == .microphone {
            try await startAudioCapture()
        }

        isListening = true
        delegate?.realtimeSTT(self, didChangeListeningState: true)

        // Initialize VAD in background (non-blocking)
        Task {
            do {
                try await vadService.initialize()
            } catch {
                #if DEBUG
                print("LocalWhisperSTT: VAD initialization failed: \(error)")
                #endif
            }
        }
    }

    func stopListening() {
        let wasListening = isListening
        isListening = false

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioLevelMonitor.stop()

        if wasListening {
            // Transcribe the recorded audio
            Task {
                await transcribeRecordedAudio()
            }
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
    }

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioSource == .external, isListening else { return }
        appendToBuffer(buffer)
    }

    private func appendToBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        vadBuffer.append(contentsOf: samples)
        bufferLock.unlock()

        // Update audio level monitor
        audioLevelMonitor.updateLevel(from: samples)

        // Process VAD for auto-stop
        Task {
            await processVADForAutoStop()
        }
    }

    private func processVADForAutoStop() async {
        guard vadService.isReady, isListening else { return }

        // Check if minimum recording time has passed
        guard let startTime = recordingStartTime,
              Date().timeIntervalSince(startTime) >= vadMinimumRecordingTime else {
            return
        }

        bufferLock.lock()
        while vadBuffer.count >= vadChunkSize {
            let chunk = Array(vadBuffer.prefix(vadChunkSize))
            vadBuffer.removeFirst(vadChunkSize)
            bufferLock.unlock()

            let result = await vadService.processSamples(chunk)

            if result.isSpeech {
                // Speech detected - reset silence timer
                silenceStartTime = nil
            } else {
                // Silence detected
                if silenceStartTime == nil {
                    silenceStartTime = Date()
                } else if let silenceStart = silenceStartTime,
                          Date().timeIntervalSince(silenceStart) >= vadSilenceDuration {
                    // Silence duration reached - auto-stop
                    #if DEBUG
                    print("LocalWhisperSTT: Auto-stop triggered after \(vadSilenceDuration)s of silence")
                    #endif
                    stopListening()
                    return
                }
            }

            bufferLock.lock()
        }
        bufferLock.unlock()
    }

    private func startAudioCapture() async throws {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw RealtimeSTTError.audioError("Failed to create audio engine")
        }

        // Set audio input device if specified
        if !audioInputDeviceUID.isEmpty,
           let device = AudioInputManager.shared.device(withUID: audioInputDeviceUID) {
            try AudioInputManager.shared.setInputDevice(device, for: audioEngine)
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Convert to mono 16kHz float for Whisper
        let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: recordingFormat, to: whisperFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Convert to Whisper format (16kHz mono)
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / recordingFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter?.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                self.appendToBuffer(convertedBuffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func transcribeRecordedAudio() async {
        bufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        vadBuffer.removeAll()
        bufferLock.unlock()

        // Need at least 0.5 seconds of audio
        guard samples.count > 8000 else {
            #if DEBUG
            print("LocalWhisperSTT: Recording too short, skipping transcription")
            #endif
            return
        }

        do {
            let rawTranscription = try await whisperKitManager.transcribeFromSamples(samples, language: selectedLanguage)
            let transcription = cleanTranscription(rawTranscription)

            if !transcription.isEmpty {
                delegate?.realtimeSTT(self, didReceiveFinalResult: transcription)
            }
        } catch {
            delegate?.realtimeSTT(self, didFailWithError: error)
        }
    }

    /// Clean up transcription by removing special tokens and artifacts
    private func cleanTranscription(_ text: String) -> String {
        var result = text

        // Remove bracketed special tokens like [BLANK_AUDIO], [MUSIC], [APPLAUSE], etc.
        if let bracketRegex = try? NSRegularExpression(pattern: "\\[[A-Z_]+\\]", options: []) {
            result = bracketRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Remove angle-bracket tokens like <|transcribe|>, <|en|>, etc.
        if let angleRegex = try? NSRegularExpression(pattern: "<\\|[^|>]+\\|>", options: []) {
            result = angleRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Remove parenthetical non-speech indicators like (music), (applause), etc.
        if let parenRegex = try? NSRegularExpression(pattern: "\\([a-zA-Z\\s]+\\)", options: []) {
            result = parenRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        WhisperModelVariant.allCases.compactMap { variant in
            // Only show downloaded models
            guard whisperKitManager.downloadStates[variant] == .downloaded else {
                return nil
            }
            return RealtimeSTTModelInfo(
                id: variant.rawValue,
                name: variant.displayName,
                description: variant.description,
                isDefault: variant == .largev3Turbo
            )
        }
    }
}
