import Foundation
@preconcurrency import AVFoundation

/// OpenAI Realtime API for true streaming speech-to-text via WebSocket
/// Uses the intent=transcription mode for real-time transcription
@MainActor
final class OpenAIRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "gpt-4o-transcribe"
    var selectedLanguage: String = ""  // "" = Auto (OpenAI auto-detects)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    // VAD auto-stop settings (OpenAI has built-in VAD, but we expose these for UI consistency)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 3.0

    private var audioEngine: AVAudioEngine?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private let apiKeyManager = APIKeyManager.shared
    // OpenAI Realtime API requires 24kHz audio
    private let sampleRate: Double = 24000

    // Audio format converter for resampling
    private var audioConverter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // Accumulated transcription text
    private var accumulatedText: String = ""
    private var currentPartialText: String = ""

    // Audio level monitoring
    private let audioLevelMonitor = AudioLevelMonitor.shared

    // Pre-buffer for initial audio (before WebSocket is ready)
    private var preBuffer: [Data] = []
    private var isPreBuffering = true
    private let preBufferLock = NSLock()

    func startListening() async throws {
        guard let apiKey = apiKeyManager.getAPIKey(for: .openAI) else {
            throw RealtimeSTTError.apiError("OpenAI API key not found")
        }

        // Stop any existing session
        stopListening()

        // Reset state
        accumulatedText = ""
        currentPartialText = ""
        preBufferLock.lock()
        preBuffer.removeAll()
        isPreBuffering = true
        preBufferLock.unlock()

        // Start audio capture FIRST to avoid missing initial audio
        if audioSource == .microphone {
            try await startAudioCapture()
        } else {
            // For external source, prepare the output format
            outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        }

        isListening = true
        audioLevelMonitor.start()
        delegate?.realtimeSTT(self, didChangeListeningState: true)

        // Connect WebSocket (audio is being pre-buffered meanwhile)
        try await connectWebSocket(apiKey: apiKey)

        // Configure the transcription session
        try await configureSession()

        // Flush pre-buffered audio
        await flushPreBuffer()
    }

    func stopListening() {
        // Stop audio engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil
        outputFormat = nil
        audioLevelMonitor.stop()

        // Clear pre-buffer
        preBufferLock.lock()
        preBuffer.removeAll()
        isPreBuffering = false
        preBufferLock.unlock()

        // Close WebSocket
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        // Send final result if there's any text
        if !accumulatedText.isEmpty || !currentPartialText.isEmpty {
            let finalText: String
            if accumulatedText.isEmpty {
                finalText = currentPartialText
            } else if currentPartialText.isEmpty {
                finalText = accumulatedText
            } else {
                finalText = accumulatedText + " " + currentPartialText
            }
            if !finalText.isEmpty {
                delegate?.realtimeSTT(self, didReceiveFinalResult: finalText)
            }
        }

        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
    }

    /// Process audio buffer from external source
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioSource == .external, isListening else { return }

        // Update audio level monitor
        if let channelData = buffer.floatChannelData {
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            audioLevelMonitor.updateLevel(from: samples)
        }

        sendAudioBuffer(buffer)
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: "gpt-4o-transcribe", name: "GPT-4o Transcribe", description: "High quality streaming transcription", isDefault: true),
            RealtimeSTTModelInfo(id: "gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe", description: "Faster, lower cost streaming"),
            RealtimeSTTModelInfo(id: "whisper-1", name: "Whisper", description: "OpenAI Whisper (full transcript on completion)")
        ]
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        // Use the transcription intent endpoint
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }

        #if DEBUG
        print("OpenAIRealtimeSTT: Connecting to \(url.absoluteString)")
        #endif

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        // Start receiving messages
        startReceivingMessages()

        // Wait for connection to establish
        try await Task.sleep(nanoseconds: 300_000_000)  // 0.3 seconds
    }

    private func configureSession() async throws {
        // Configure the transcription session
        let model = selectedModel.isEmpty ? "gpt-4o-transcribe" : selectedModel

        var config: [String: Any] = [
            "type": "transcription_session.update",
            "session": [
                "input_audio_transcription": [
                    "model": model
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ],
                "input_audio_format": "pcm16"
            ]
        ]

        // Add language if specified
        if !selectedLanguage.isEmpty {
            if var session = config["session"] as? [String: Any],
               var transcription = session["input_audio_transcription"] as? [String: Any] {
                transcription["language"] = selectedLanguage
                session["input_audio_transcription"] = transcription
                config["session"] = session
            }
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw RealtimeSTTError.apiError("Failed to serialize session config")
        }

        #if DEBUG
        print("OpenAIRealtimeSTT: Sending session config: \(jsonString)")
        #endif

        try await webSocketTask?.send(.string(jsonString))
    }

    private func startReceivingMessages() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }

                switch result {
                case .success(let message):
                    self.handleWebSocketMessage(message)
                    // Continue receiving if WebSocket is still active
                    if self.webSocketTask != nil {
                        self.startReceivingMessages()
                    }

                case .failure(let error):
                    #if DEBUG
                    print("OpenAIRealtimeSTT: WebSocket receive error: \(error)")
                    #endif
                    if self.isListening {
                        self.delegate?.realtimeSTT(self, didFailWithError: error)
                    }
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            return
        }

        #if DEBUG
        if eventType != "input_audio_buffer.speech_started" &&
           eventType != "input_audio_buffer.speech_stopped" {
            print("OpenAIRealtimeSTT: Received event: \(eventType)")
        }
        #endif

        switch eventType {
        case "session.created", "transcription_session.created":
            #if DEBUG
            print("OpenAIRealtimeSTT: Session created")
            #endif

        case "session.updated", "transcription_session.updated":
            #if DEBUG
            print("OpenAIRealtimeSTT: Session updated")
            #endif

        case "conversation.item.input_audio_transcription.delta":
            // Incremental transcription (for gpt-4o-transcribe models)
            if let delta = json["delta"] as? String, !delta.isEmpty {
                currentPartialText += delta
                let fullText = accumulatedText.isEmpty ? currentPartialText : accumulatedText + " " + currentPartialText
                delegate?.realtimeSTT(self, didReceivePartialResult: fullText)
            }

        case "conversation.item.input_audio_transcription.completed":
            // Final transcription for a segment
            if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                // Commit the transcript
                if accumulatedText.isEmpty {
                    accumulatedText = transcript
                } else {
                    accumulatedText += " " + transcript
                }
                currentPartialText = ""
                delegate?.realtimeSTT(self, didReceivePartialResult: accumulatedText)

                #if DEBUG
                print("OpenAIRealtimeSTT: Transcription completed: '\(transcript.prefix(50))...'")
                #endif
            }

        case "input_audio_buffer.speech_started":
            #if DEBUG
            print("OpenAIRealtimeSTT: Speech started")
            #endif

        case "input_audio_buffer.speech_stopped":
            #if DEBUG
            print("OpenAIRealtimeSTT: Speech stopped")
            #endif

        case "input_audio_buffer.committed":
            #if DEBUG
            print("OpenAIRealtimeSTT: Audio buffer committed")
            #endif

        case "error":
            let errorMessage = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            #if DEBUG
            print("OpenAIRealtimeSTT: Error: \(errorMessage)")
            #endif
            delegate?.realtimeSTT(self, didFailWithError: RealtimeSTTError.apiError(errorMessage))

        default:
            #if DEBUG
            if !eventType.starts(with: "rate_limits") {
                print("OpenAIRealtimeSTT: Unhandled event type: \(eventType)")
            }
            #endif
        }
    }

    // MARK: - Audio Capture

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
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Prepare output format (24kHz, mono, 16-bit PCM for OpenAI)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw RealtimeSTTError.audioError("Failed to create output format")
        }
        outputFormat = outFormat

        // Create converter if sample rate differs
        if inputFormat.sampleRate != sampleRate || inputFormat.channelCount != 1 {
            audioConverter = AVAudioConverter(from: inputFormat, to: outFormat)
        }

        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Update audio level monitor
            if let channelData = buffer.floatChannelData {
                let frameLength = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                self.audioLevelMonitor.updateLevel(from: samples)
            }

            self.sendAudioBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isListening else { return }

        let pcmData: Data

        if let converter = audioConverter, let outFormat = outputFormat {
            // Need to convert format
            let ratio = outFormat.sampleRate / buffer.format.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputFrameCapacity) else {
                return
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .error || error != nil {
                return
            }

            pcmData = bufferToData(outputBuffer)
        } else if buffer.format.commonFormat == .pcmFormatInt16 {
            // Already in correct format
            pcmData = bufferToData(buffer)
        } else {
            // Convert float to int16
            pcmData = convertFloatBufferToInt16Data(buffer)
        }

        if pcmData.isEmpty {
            return
        }

        // Check if we should pre-buffer or send directly
        preBufferLock.lock()
        let shouldPreBuffer = isPreBuffering
        preBufferLock.unlock()

        if shouldPreBuffer {
            preBufferLock.lock()
            preBuffer.append(pcmData)
            preBufferLock.unlock()
        } else {
            sendAudioData(pcmData)
        }
    }

    private func flushPreBuffer() async {
        preBufferLock.lock()
        let buffersToFlush = preBuffer
        preBuffer.removeAll()
        isPreBuffering = false
        preBufferLock.unlock()

        #if DEBUG
        print("OpenAIRealtimeSTT: Flushing \(buffersToFlush.count) pre-buffered audio chunks")
        #endif

        for data in buffersToFlush {
            sendAudioData(data)
            // Small delay to avoid overwhelming the WebSocket
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }

    private func sendAudioData(_ pcmData: Data) {
        guard let webSocketTask = webSocketTask else { return }

        // Send as base64 encoded audio using input_audio_buffer.append
        let base64Audio = pcmData.base64EncodedString()

        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        webSocketTask.send(.string(jsonString)) { error in
            if let error = error {
                #if DEBUG
                print("OpenAIRealtimeSTT: Send error: \(error)")
                #endif
            }
        }
    }

    private func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let int16Data = buffer.int16ChannelData else { return Data() }
        let frameLength = Int(buffer.frameLength)
        return Data(bytes: int16Data[0], count: frameLength * 2)
    }

    private func convertFloatBufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let floatData = buffer.floatChannelData else { return Data() }
        let frameLength = Int(buffer.frameLength)

        var int16Data = [Int16](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let sample = floatData[0][i]
            let clipped = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clipped * 32767.0)
        }

        return Data(bytes: int16Data, count: frameLength * 2)
    }
}
