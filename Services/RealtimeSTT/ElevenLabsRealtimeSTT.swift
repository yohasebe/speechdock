import Foundation
@preconcurrency import AVFoundation

/// ElevenLabs Scribe WebSocket API for real-time speech-to-text
@MainActor
final class ElevenLabsRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "scribe_v2_realtime"
    var selectedLanguage: String = ""  // "" = Auto (ElevenLabs auto-detects)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    // VAD auto-stop settings (not used by ElevenLabs streaming, but required by protocol)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 3.0

    private var audioEngine: AVAudioEngine?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private let apiKeyManager = APIKeyManager.shared
    private let sampleRate: Double = 16000

    // Audio format converter for resampling
    private var audioConverter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // Accumulated committed text (ElevenLabs resets partial transcripts after each commit)
    private var committedText: String = ""
    // Current partial text (not yet committed) - needed to preserve on stop
    private var currentPartialText: String = ""

    // Audio level monitoring
    private let audioLevelMonitor = AudioLevelMonitor.shared

    // Connection state tracking
    private var sessionStarted = false

    // Auto-reconnect support
    private var isIntentionallyStopping = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3

    func startListening() async throws {
        guard let apiKey = apiKeyManager.getAPIKey(for: .elevenLabs) else {
            throw RealtimeSTTError.apiError("ElevenLabs API key not found")
        }

        // Stop any existing session
        stopListening()

        isIntentionallyStopping = false
        reconnectAttempts = 0

        // Reset accumulated text
        committedText = ""
        currentPartialText = ""

        // Connect WebSocket
        try await connectWebSocket(apiKey: apiKey)

        // Start audio capture
        if audioSource == .microphone {
            try await startAudioCapture()
        } else {
            // For external source, prepare the output format
            outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        }

        isListening = true
        audioLevelMonitor.start()
        delegate?.realtimeSTT(self, didChangeListeningState: true)
    }

    func stopListening() {
        isIntentionallyStopping = true

        // Stop audio engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil
        outputFormat = nil
        audioLevelMonitor.stop()

        // Close WebSocket
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        // Only send final result if there's uncommitted partial text to preserve
        // (committed text was already sent via didReceivePartialResult)
        if !currentPartialText.isEmpty {
            let finalText: String
            if committedText.isEmpty {
                finalText = currentPartialText
            } else {
                finalText = committedText + " " + currentPartialText
            }
            delegate?.realtimeSTT(self, didReceiveFinalResult: finalText)
        }

        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
    }

    /// Process audio buffer from external source
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioSource == .external, isListening else { return }
        sendAudioBuffer(buffer)
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        // Map old model IDs to realtime versions
        var model = selectedModel.isEmpty ? "scribe_v2_realtime" : selectedModel
        if model == "scribe_v2" || model == "scribe_v1" {
            model = "scribe_v2_realtime"
        }

        var urlComponents = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        urlComponents.queryItems = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "sample_rate", value: "\(Int(sampleRate))"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "include_language_detection", value: "true")
        ]

        // Add language if specified (recommended for better accuracy)
        if !selectedLanguage.isEmpty {
            urlComponents.queryItems?.append(URLQueryItem(name: "language_code", value: selectedLanguage))
        }

        guard let url = urlComponents.url else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }

        #if DEBUG
        print("ElevenLabsRealtimeSTT: Connecting to \(url.absoluteString)")
        print("ElevenLabsRealtimeSTT: Language code = '\(selectedLanguage)' (empty = auto-detect)")
        #endif

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        sessionStarted = false
        task.resume()

        // Start receiving messages
        startReceivingMessages()

        // Wait for session_started confirmation with timeout
        try await waitForSessionStart(timeout: 5.0)
    }

    /// Wait for session_started event from the server
    /// - Parameter timeout: Maximum time to wait in seconds
    /// - Throws: RealtimeSTTError if timeout or connection fails
    private func waitForSessionStart(timeout: TimeInterval) async throws {
        let startTime = Date()
        while !sessionStarted {
            // Check if WebSocket was closed or cancelled
            if webSocketTask == nil || webSocketTask?.state == .completed || webSocketTask?.state == .canceling {
                throw RealtimeSTTError.connectionError("WebSocket connection closed unexpectedly")
            }

            // Check timeout
            if Date().timeIntervalSince(startTime) > timeout {
                throw RealtimeSTTError.connectionError("Connection timeout: server did not respond within \(Int(timeout)) seconds")
            }

            // Poll every 50ms
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #if DEBUG
        let elapsed = Date().timeIntervalSince(startTime)
        print("ElevenLabsRealtimeSTT: Session started after \(String(format: "%.2f", elapsed))s")
        #endif
    }

    private func startReceivingMessages() {
        Task { [weak self] in
            while let self = self, let task = self.webSocketTask, task.state == .running {
                do {
                    let message = try await task.receive()
                    await MainActor.run {
                        self.handleWebSocketMessage(message)
                    }
                } catch {
                    await MainActor.run {
                        if self.isListening && !self.isIntentionallyStopping {
                            Task {
                                await self.handleUnexpectedDisconnection()
                            }
                        } else if self.isListening {
                            self.delegate?.realtimeSTT(self, didFailWithError: error)
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleUnexpectedDisconnection() async {
        guard !isIntentionallyStopping, reconnectAttempts < maxReconnectAttempts else {
            if isListening {
                // Send accumulated text before reporting error so it's not lost
                let fullText = committedText.isEmpty ? currentPartialText :
                    (currentPartialText.isEmpty ? committedText : committedText + " " + currentPartialText)
                if !fullText.isEmpty {
                    delegate?.realtimeSTT(self, didReceivePartialResult: fullText)
                }
                let error = RealtimeSTTError.connectionError("Connection lost after \(maxReconnectAttempts) reconnect attempts")
                delegate?.realtimeSTT(self, didFailWithError: error)
            }
            return
        }
        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts - 1))  // 1s, 2s, 4s

        #if DEBUG
        print("ElevenLabsRealtimeSTT: Reconnecting attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay)s")
        #endif

        delegate?.realtimeSTT(self, didReceivePartialResult: "[Reconnecting...]")

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionStarted = false

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard isListening, !isIntentionallyStopping else { return }

        do {
            guard let apiKey = apiKeyManager.getAPIKey(for: .elevenLabs) else {
                throw RealtimeSTTError.apiError("API key not available")
            }
            try await connectWebSocket(apiKey: apiKey)
            reconnectAttempts = 0
            #if DEBUG
            print("ElevenLabsRealtimeSTT: Reconnected successfully")
            #endif
        } catch {
            #if DEBUG
            print("ElevenLabsRealtimeSTT: Reconnect failed: \(error)")
            #endif
            await handleUnexpectedDisconnection()
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseTranscriptionMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseTranscriptionMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func parseTranscriptionMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else {
            #if DEBUG
            print("ElevenLabsRealtimeSTT: Failed to parse message: \(jsonString.prefix(200))")
            #endif
            return
        }

        switch messageType {
        case "session_started":
            sessionStarted = true
            #if DEBUG
            print("ElevenLabsRealtimeSTT: Session started")
            #endif

        case "partial_transcript":
            if let text = json["text"] as? String, !text.isEmpty {
                // Track current partial text
                currentPartialText = text
                // Combine committed text with current partial text
                let fullText = committedText.isEmpty ? text : committedText + " " + text
                delegate?.realtimeSTT(self, didReceivePartialResult: fullText)
            } else {
                // Empty partial - clear current partial
                currentPartialText = ""
                if !committedText.isEmpty {
                    delegate?.realtimeSTT(self, didReceivePartialResult: committedText)
                }
            }

        case "committed_transcript", "committed_transcript_with_timestamps":
            if let text = json["text"] as? String, !text.isEmpty {
                #if DEBUG
                // Log detected language for debugging
                if let detectedLang = json["language_code"] as? String {
                    print("ElevenLabsRealtimeSTT: Detected language = '\(detectedLang)', text = '\(text.prefix(50))...'")
                }
                print("ElevenLabsRealtimeSTT: Committed text received: '\(text.prefix(100))...'")
                print("ElevenLabsRealtimeSTT: Current committedText: '\(committedText.suffix(100))...'")
                #endif

                // Deduplicate: check if this text is already part of our committed text
                // This handles cases where ElevenLabs resends previously committed text
                if committedText.isEmpty {
                    committedText = text
                } else if !committedText.hasSuffix(text) && !committedText.contains(text) {
                    // Only append if this text is genuinely new
                    committedText += " " + text
                } else {
                    #if DEBUG
                    print("ElevenLabsRealtimeSTT: Skipped duplicate committed text")
                    #endif
                }

                // Clear partial text since it's now committed
                currentPartialText = ""
                // Show accumulated text as partial result (final is only sent when stopping)
                delegate?.realtimeSTT(self, didReceivePartialResult: committedText)
            }

        case "error", "invalid_request":
            let errorMessage = json["error"] as? String ?? json["message"] as? String ?? "Unknown error"
            delegate?.realtimeSTT(self, didFailWithError: RealtimeSTTError.apiError(errorMessage))
            stopListening()

        default:
            break
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

        // Prepare output format (16kHz, mono, 16-bit PCM)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw RealtimeSTTError.audioError("Failed to create output format")
        }
        outputFormat = outFormat

        // Create converter if sample rate differs
        if inputFormat.sampleRate != sampleRate || inputFormat.channelCount != 1 {
            audioConverter = AVAudioConverter(from: inputFormat, to: outFormat)
        }

        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.sendAudioBuffer(buffer)

            // Update audio level monitor
            if let channelData = buffer.floatChannelData {
                let frameLength = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                self?.audioLevelMonitor.updateLevel(from: samples)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isListening, let webSocketTask = webSocketTask else { return }

        let pcmData: Data

        if let converter = audioConverter, let outFormat = outputFormat {
            // Need to convert format
            let ratio = outFormat.sampleRate / buffer.format.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputFrameCapacity) else {
                #if DEBUG
                print("ElevenLabsRealtimeSTT: Failed to create output buffer (capacity: \(outputFrameCapacity))")
                #endif
                return
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .error || error != nil {
                #if DEBUG
                print("ElevenLabsRealtimeSTT: Audio conversion failed - status: \(status.rawValue), error: \(error?.localizedDescription ?? "none")")
                #endif
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
            #if DEBUG
            print("ElevenLabsRealtimeSTT: Empty PCM data after conversion")
            #endif
            return
        }

        // Send as base64 encoded audio chunk
        let base64Audio = pcmData.base64EncodedString()
        let message: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": base64Audio
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            webSocketTask.send(.string(jsonString)) { _ in }
        } else {
            #if DEBUG
            print("ElevenLabsRealtimeSTT: Failed to serialize audio buffer message")
            #endif
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

        return Data(bytes: &int16Data, count: frameLength * 2)
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: "scribe_v2_realtime", name: "Scribe v2 Realtime", description: "~150ms latency streaming", isDefault: true)
        ]
    }
}
