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

    // VAD settings for turn detection
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 0.5  // 500ms

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
    // Maximum pre-buffer size (~5 seconds at 24kHz 16-bit mono = 240KB)
    private let maxPreBufferSize = 250_000

    // Settling time to skip initial mic noise (in seconds)
    private let micSettlingTime: TimeInterval = 0.3
    private var audioStartTime: Date?

    // Connection state tracking
    private var sessionCreated = false

    func startListening() async throws {
        guard let apiKey = apiKeyManager.getAPIKey(for: .openAI) else {
            throw RealtimeSTTError.apiError("OpenAI API key not found")
        }

        // Stop any existing session
        stopListening()

        // Reset state
        accumulatedText = ""
        currentPartialText = ""
        audioStartTime = nil
        preBufferLock.lock()
        preBuffer.removeAll()
        isPreBuffering = true
        preBufferLock.unlock()

        // Mark when audio capture starts for settling time (applies to both mic and external)
        audioStartTime = Date()

        // Start audio capture FIRST to avoid missing initial audio
        if audioSource == .microphone {
            try await startAudioCapture()
        } else {
            // For external source, prepare the output format and converter
            // SystemAudioCaptureService outputs 16kHz float mono, we need 24kHz int16 mono
            guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
                throw RealtimeSTTError.audioError("Failed to create output format")
            }
            outputFormat = outFormat

            // Create input format matching SystemAudioCaptureService (16kHz float mono)
            guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
                throw RealtimeSTTError.audioError("Failed to create input format")
            }

            // Create converter for resampling 16kHz -> 24kHz
            audioConverter = AVAudioConverter(from: inputFormat, to: outFormat)
        }

        isListening = true
        audioLevelMonitor.start()
        delegate?.realtimeSTT(self, didChangeListeningState: true)

        // Connect WebSocket (audio is being pre-buffered meanwhile)
        try await connectWebSocket(apiKey: apiKey)

        // Brief calibration period to measure noise floor (audio is being captured)
        // This allows adaptive VAD parameters based on background noise
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        // Configure the transcription session with adaptive VAD parameters
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
        sessionCreated = false
        task.resume()

        // Start receiving messages
        startReceivingMessages()

        // Wait for session.created event with timeout
        try await waitForSessionCreated(timeout: 5.0)
    }

    /// Wait for session.created event from the server
    /// - Parameter timeout: Maximum time to wait in seconds
    /// - Throws: RealtimeSTTError if timeout or connection fails
    private func waitForSessionCreated(timeout: TimeInterval) async throws {
        let startTime = Date()
        while !sessionCreated {
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
        print("OpenAIRealtimeSTT: Session created after \(String(format: "%.2f", elapsed))s")
        #endif
    }

    private func configureSession() async throws {
        // Configure the transcription session
        let model = selectedModel.isEmpty ? "gpt-4o-transcribe" : selectedModel

        // VAD parameters differ based on audio source
        let threshold: NSDecimalNumber
        let silenceDurationMs: Int
        let prefixPaddingMs: Int

        if audioSource == .external {
            // External source (system audio like videos):
            // - Videos often have background music that never fully stops
            // - Need lower threshold to detect speech amid background audio
            // - Need shorter silence duration since true silence is rare
            threshold = NSDecimalNumber(string: "0.25")
            silenceDurationMs = 250  // Shorter to finalize faster
            prefixPaddingMs = 200

            #if DEBUG
            print("OpenAIRealtimeSTT: External source VAD - threshold: \(threshold), silence: \(silenceDurationMs)ms")
            #endif
        } else {
            // Microphone: Use adaptive VAD parameters based on detected noise floor
            let adaptiveThreshold = audioLevelMonitor.recommendedVADThreshold()
            let adaptiveSilenceMs = audioLevelMonitor.recommendedSilenceDuration()

            // Use NSDecimalNumber to ensure exact decimal representation in JSON
            threshold = NSDecimalNumber(string: String(format: "%.2f", adaptiveThreshold))
            silenceDurationMs = adaptiveSilenceMs
            prefixPaddingMs = 300

            #if DEBUG
            print("OpenAIRealtimeSTT: Microphone VAD - threshold: \(threshold), silence: \(silenceDurationMs)ms, noise floor: \(audioLevelMonitor.noiseFloor)")
            #endif
        }

        var config: [String: Any] = [
            "type": "transcription_session.update",
            "session": [
                "input_audio_transcription": [
                    "model": model
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": threshold,
                    "prefix_padding_ms": prefixPaddingMs,
                    "silence_duration_ms": silenceDurationMs
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
        Task { [weak self] in
            while let self = self, let task = self.webSocketTask, task.state == .running {
                do {
                    let message = try await task.receive()
                    await MainActor.run {
                        self.handleWebSocketMessage(message)
                    }
                } catch {
                    await MainActor.run {
                        #if DEBUG
                        print("OpenAIRealtimeSTT: WebSocket receive error: \(error)")
                        #endif
                        if self.isListening {
                            self.delegate?.realtimeSTT(self, didFailWithError: error)
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            // Try UTF-8 first, then fall back to other encodings
            var decoded = false
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
                decoded = true
            } else if let text = String(data: data, encoding: .utf16) {
                parseMessage(text)
                decoded = true
            } else if let text = String(data: data, encoding: .isoLatin1) {
                // Last resort - convert to UTF-8 via latin1
                parseMessage(text)
                decoded = true
            }
            #if DEBUG
            if !decoded {
                print("OpenAIRealtimeSTT: Failed to decode WebSocket data as string")
            }
            #endif
        @unknown default:
            break
        }
    }

    private func parseMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            #if DEBUG
            print("OpenAIRealtimeSTT: Failed to parse message: \(jsonString.prefix(200))")
            #endif
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
            sessionCreated = true
            #if DEBUG
            print("OpenAIRealtimeSTT: Session created")
            #endif

        case "session.updated", "transcription_session.updated":
            #if DEBUG
            print("OpenAIRealtimeSTT: Session updated")
            #endif

        case "conversation.item.input_audio_transcription.delta",
             "transcription.delta":
            // Incremental transcription (for gpt-4o-transcribe models)
            // Handle both event types for compatibility
            if let rawDelta = json["delta"] as? String, !rawDelta.isEmpty {
                // Normalize Unicode to NFC form for consistent handling of non-ASCII characters
                // Also handle potential invalid UTF-8 sequences
                let delta = sanitizeUnicodeString(rawDelta)
                currentPartialText += delta
                let fullText = accumulatedText.isEmpty ? currentPartialText : accumulatedText + " " + currentPartialText
                delegate?.realtimeSTT(self, didReceivePartialResult: fullText)
                #if DEBUG
                print("OpenAIRealtimeSTT: Delta text: '\(delta)'")
                #endif
            }

        case "conversation.item.input_audio_transcription.completed",
             "transcription.done":
            // Final transcription for a segment
            // Handle both event types for compatibility
            if let rawTranscript = json["transcript"] as? String, !rawTranscript.isEmpty {
                // Normalize and sanitize Unicode
                let transcript = sanitizeUnicodeString(rawTranscript)
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

        // Skip audio during settling time to avoid initial noise being transcribed
        // Applies to both microphone and external sources (system/app audio)
        if let startTime = audioStartTime,
           Date().timeIntervalSince(startTime) < micSettlingTime {
            return
        }

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
            // Limit pre-buffer size to prevent memory issues during slow connections
            let currentSize = preBuffer.reduce(0) { $0 + $1.count }
            if currentSize + pcmData.count > maxPreBufferSize {
                // Remove oldest data to make room (keep most recent audio)
                var sizeToRemove = currentSize + pcmData.count - maxPreBufferSize
                while sizeToRemove > 0 && !preBuffer.isEmpty {
                    sizeToRemove -= preBuffer.removeFirst().count
                }
            }
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
            #if DEBUG
            print("OpenAIRealtimeSTT: Failed to serialize audio buffer message")
            #endif
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

    /// Sanitize and normalize Unicode string for proper display
    /// Handles potential encoding issues with non-ASCII characters (Japanese, etc.)
    private func sanitizeUnicodeString(_ input: String) -> String {
        // First, normalize to NFC (Canonical Decomposition, followed by Canonical Composition)
        // This ensures consistent representation of characters like Japanese
        var result = input.precomposedStringWithCanonicalMapping

        // Remove any invalid Unicode scalar values (replacement characters)
        result = result.unicodeScalars.filter { scalar in
            // Keep valid scalars, filter out replacement character (U+FFFD)
            scalar != Unicode.Scalar(0xFFFD)
        }.map { String($0) }.joined()

        // Handle potential UTF-8 BOM or other invisible characters at start
        if let first = result.unicodeScalars.first,
           first == Unicode.Scalar(0xFEFF) {
            result = String(result.dropFirst())
        }

        return result
    }
}
