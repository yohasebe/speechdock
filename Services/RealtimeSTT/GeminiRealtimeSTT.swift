import Foundation
@preconcurrency import AVFoundation

/// Google Gemini Live API for true streaming speech-to-text via WebSocket
@MainActor
final class GeminiRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "gemini-2.5-flash-native-audio-preview-12-2025"
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    // VAD auto-stop settings (Gemini has built-in VAD)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 3.0

    private var audioEngine: AVAudioEngine?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private let apiKeyManager = APIKeyManager.shared
    // Gemini Live API uses 16kHz audio
    private let sampleRate: Double = 16000

    // Audio format converter for resampling
    private var audioConverter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // Accumulated transcription text
    private var accumulatedText: String = ""

    // Audio level monitoring
    private let audioLevelMonitor = AudioLevelMonitor.shared

    // Pre-buffer for initial audio (before WebSocket is ready)
    private var preBuffer: [Data] = []
    private var isPreBuffering = true
    private let preBufferLock = NSLock()
    // Maximum pre-buffer size (~5 seconds at 16kHz 16-bit mono = 160KB)
    private let maxPreBufferSize = 170_000

    // Settling time to skip initial mic noise (in seconds)
    private let micSettlingTime: TimeInterval = 0.3
    private var audioStartTime: Date?

    // Connection state
    private var isSetupComplete = false
    private var isWebSocketConnected = false

    // Auto-reconnect support
    private var isIntentionallyStopping = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3

    func startListening() async throws {
        guard let apiKey = apiKeyManager.getAPIKey(for: .gemini) else {
            throw RealtimeSTTError.apiError("Gemini API key not found")
        }

        // Stop any existing session
        stopListening()

        isIntentionallyStopping = false
        reconnectAttempts = 0

        // Reset state
        accumulatedText = ""
        isSetupComplete = false
        isWebSocketConnected = false
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
            // For external source, prepare the output format
            outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        }

        isListening = true
        audioLevelMonitor.start()
        delegate?.realtimeSTT(self, didChangeListeningState: true)

        do {
            // Connect WebSocket (audio is being pre-buffered meanwhile)
            try await connectWebSocket(apiKey: apiKey)

            // Send setup message
            try await sendSetupMessage()

            // Wait for setup complete
            try await Task.sleep(nanoseconds: 300_000_000)  // 0.3 seconds

            // Flush pre-buffered audio
            await flushPreBuffer()
        } catch {
            // Clean up on error
            #if DEBUG
            print("GeminiRealtimeSTT: startListening failed: \(error)")
            #endif
            stopListening()
            throw error
        }
    }

    func stopListening() {
        isIntentionallyStopping = true

        #if DEBUG
        print("GeminiRealtimeSTT: stopListening called, isListening=\(isListening)")
        #endif

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
        isWebSocketConnected = false

        // Send final result if there's any text
        if !accumulatedText.isEmpty {
            delegate?.realtimeSTT(self, didReceiveFinalResult: accumulatedText)
        }

        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }

        isSetupComplete = false

        #if DEBUG
        print("GeminiRealtimeSTT: stopListening completed")
        #endif
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
            RealtimeSTTModelInfo(id: "gemini-2.5-flash-native-audio-preview-12-2025", name: "Gemini 2.5 Flash Native Audio", description: "Native audio with transcription support", isDefault: true),
            RealtimeSTTModelInfo(id: "gemini-2.0-flash-live-001", name: "Gemini 2.0 Flash Live", description: "Fast streaming (limited transcription)")
        ]
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        // Gemini Live API WebSocket endpoint (using v1beta)
        guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)") else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }

        #if DEBUG
        print("GeminiRealtimeSTT: Connecting to WebSocket...")
        #endif

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300

        // Use OperationQueue.main for delegate callbacks to avoid threading issues
        let session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
        urlSession = session

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        // Start receiving messages
        startReceivingMessages()

        // Wait for connection with timeout
        let startTime = Date()
        let timeout: TimeInterval = 10.0

        while !isWebSocketConnected {
            if Date().timeIntervalSince(startTime) > timeout {
                throw RealtimeSTTError.apiError("WebSocket connection timeout")
            }
            try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
        }

        #if DEBUG
        print("GeminiRealtimeSTT: WebSocket connected")
        #endif
    }

    private func sendSetupMessage() async throws {
        let model = selectedModel.isEmpty ? "gemini-2.5-flash-native-audio-preview-12-2025" : selectedModel

        // System instruction for proper transcription formatting
        // Japanese/Chinese/Korean don't use inter-word spacing
        let systemInstructionText = """
            You are a speech transcription assistant. When transcribing audio:
            - For Japanese, Chinese, or Korean: Do NOT insert spaces between words or morphemes. Output natural text without spaces.
            - For English and other Western languages: Use normal word spacing.
            - Output only the transcription, no explanations.
            """

        // For transcription-only mode, use AUDIO modality with inputAudioTranscription enabled
        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": systemInstructionText]
                    ]
                ],
                "inputAudioTranscription": [:]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: setup),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw RealtimeSTTError.apiError("Failed to serialize setup message")
        }

        #if DEBUG
        print("GeminiRealtimeSTT: Sending setup: \(jsonString)")
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
                        print("GeminiRealtimeSTT: WebSocket receive error: \(error)")
                        #endif
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
                if !accumulatedText.isEmpty {
                    delegate?.realtimeSTT(self, didReceivePartialResult: accumulatedText)
                }
                let error = RealtimeSTTError.connectionError("Connection lost after \(maxReconnectAttempts) reconnect attempts")
                delegate?.realtimeSTT(self, didFailWithError: error)
            }
            return
        }
        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts - 1))  // 1s, 2s, 4s

        #if DEBUG
        print("GeminiRealtimeSTT: Reconnecting attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay)s")
        #endif

        delegate?.realtimeSTT(self, didReceivePartialResult: "[Reconnecting...]")

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isWebSocketConnected = false
        isSetupComplete = false

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard isListening, !isIntentionallyStopping else { return }

        do {
            guard let apiKey = apiKeyManager.getAPIKey(for: .gemini) else {
                throw RealtimeSTTError.apiError("API key not available")
            }
            try await connectWebSocket(apiKey: apiKey)
            try await sendSetupMessage()
            reconnectAttempts = 0
            #if DEBUG
            print("GeminiRealtimeSTT: Reconnected successfully")
            #endif
        } catch {
            #if DEBUG
            print("GeminiRealtimeSTT: Reconnect failed: \(error)")
            #endif
            await handleUnexpectedDisconnection()
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if DEBUG
            print("GeminiRealtimeSTT: Failed to parse message: \(jsonString.prefix(200))")
            #endif
            return
        }

        #if DEBUG
        // Log full message for debugging
        print("GeminiRealtimeSTT: Received message: \(jsonString.prefix(500))")
        #endif

        // Check for setup complete
        if json["setupComplete"] != nil {
            isSetupComplete = true
            #if DEBUG
            print("GeminiRealtimeSTT: Setup complete")
            #endif
            return
        }

        // Check for input transcription at top level
        if let inputTranscription = json["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String, !text.isEmpty {
            appendTranscriptionText(text)
            #if DEBUG
            print("GeminiRealtimeSTT: Transcription (top-level): '\(text)' -> accumulated: '\(accumulatedText.suffix(100))'")
            #endif
            delegate?.realtimeSTT(self, didReceivePartialResult: accumulatedText)
            return
        }

        // Check for server content (transcription may be nested here)
        if let serverContent = json["serverContent"] as? [String: Any] {
            #if DEBUG
            print("GeminiRealtimeSTT: serverContent keys: \(serverContent.keys)")
            #endif

            // Check for inputTranscription in serverContent
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String, !text.isEmpty {
                appendTranscriptionText(text)
                #if DEBUG
                print("GeminiRealtimeSTT: Transcription (serverContent): '\(text)'")
                #endif
                delegate?.realtimeSTT(self, didReceivePartialResult: accumulatedText)
            }

            // Check for turnComplete to send final result
            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                #if DEBUG
                print("GeminiRealtimeSTT: Turn complete")
                #endif
            }
            return
        }

        // Check for errors
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            #if DEBUG
            print("GeminiRealtimeSTT: Error: \(message)")
            #endif
            delegate?.realtimeSTT(self, didFailWithError: RealtimeSTTError.apiError(message))
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

        // Prepare output format (16kHz, mono, 16-bit PCM for Gemini)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw RealtimeSTTError.audioError("Failed to create output format")
        }
        outputFormat = outFormat

        // Create converter if sample rate differs
        if inputFormat.sampleRate != sampleRate || inputFormat.channelCount != 1 {
            audioConverter = AVAudioConverter(from: inputFormat, to: outFormat)
        }

        // Capture converter and format for use in tap closure
        let capturedConverter = audioConverter
        let capturedFormat = outputFormat

        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Extract samples for level monitoring
            var samples: [Float]?
            if let channelData = buffer.floatChannelData {
                let frameLength = Int(buffer.frameLength)
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            }

            // Process audio data with resampling (can be done on background thread)
            let pcmData = self.convertBufferToData(buffer, converter: capturedConverter, outFormat: capturedFormat)

            // Update UI and send data on main thread
            DispatchQueue.main.async {
                if let samples = samples {
                    self.audioLevelMonitor.updateLevel(from: samples)
                }
                self.sendPCMData(pcmData)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Convert buffer to PCM data with optional resampling
    /// Parameters are passed to allow calling from background thread
    nonisolated private func convertBufferToData(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter?, outFormat: AVAudioFormat?) -> Data {
        // Need to resample if converter is provided
        guard let converter = converter, let outFormat = outFormat else {
            // No converter needed - just convert format
            if buffer.format.commonFormat == .pcmFormatInt16 {
                return bufferToData(buffer)
            } else {
                return convertFloatBufferToInt16Data(buffer)
            }
        }

        // Calculate output frame capacity based on sample rate ratio
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputFrameCapacity) else {
            return Data()
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error || error != nil {
            #if DEBUG
            print("GeminiRealtimeSTT: Audio conversion error: \(error?.localizedDescription ?? "unknown")")
            #endif
            return Data()
        }

        return bufferToData(outputBuffer)
    }

    /// Send PCM data - must be called from main thread
    private func sendPCMData(_ pcmData: Data) {
        guard isListening, !pcmData.isEmpty else { return }

        // Skip audio during settling time to avoid initial noise being transcribed
        // Applies to both microphone and external sources (system/app audio)
        if let startTime = audioStartTime,
           Date().timeIntervalSince(startTime) < micSettlingTime {
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

    /// For external audio source - called from main thread
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
        print("GeminiRealtimeSTT: Flushing \(buffersToFlush.count) pre-buffered audio chunks")
        #endif

        for data in buffersToFlush {
            sendAudioData(data)
            // Small delay to avoid overwhelming the WebSocket
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }

    private func sendAudioData(_ pcmData: Data) {
        guard let webSocketTask = webSocketTask, isSetupComplete else { return }

        // Send as base64 encoded audio using realtimeInput with mediaChunks
        let base64Audio = pcmData.base64EncodedString()

        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": base64Audio
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            #if DEBUG
            print("GeminiRealtimeSTT: Failed to serialize audio buffer message")
            #endif
            return
        }

        webSocketTask.send(.string(jsonString)) { error in
            if let error = error {
                #if DEBUG
                print("GeminiRealtimeSTT: Send error: \(error)")
                #endif
            }
        }
    }

    /// Append transcription text - Gemini sends incremental fragments
    private func appendTranscriptionText(_ newText: String) {
        guard !newText.isEmpty else { return }

        #if DEBUG
        let debugText = newText.replacingOccurrences(of: " ", with: "␣")
        print("GeminiRealtimeSTT: appendTranscriptionText")
        print("  - newText (raw): '\(debugText)'")
        print("  - accumulatedText before: '\(accumulatedText.suffix(80))'")
        #endif

        var processedText = newText

        // Check if we're in CJK context (accumulated text ends with CJK or new text contains CJK)
        let lastCharIsCJK = accumulatedText.last.map { isCJKCharacter($0) } ?? false
        let newTextHasCJK = containsCJKCharacters(newText)

        if newTextHasCJK {
            // New text contains CJK - remove all spaces
            processedText = newText.replacingOccurrences(of: " ", with: "")
        } else if lastCharIsCJK {
            // Previous text ended with CJK - remove leading spaces from this fragment
            // This handles cases where Gemini sends " " as a separate fragment
            processedText = newText.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        }

        // Skip if processed text is empty (was just whitespace)
        guard !processedText.isEmpty else { return }

        accumulatedText += processedText

        #if DEBUG
        print("  - processedText: '\(processedText)'")
        print("  - accumulatedText after: '\(accumulatedText.suffix(80))'")
        #endif
    }

    /// Check if a single character is CJK
    private func isCJKCharacter(_ char: Character) -> Bool {
        for scalar in char.unicodeScalars {
            if isCJKScalar(scalar) {
                return true
            }
        }
        return false
    }

    /// Check if string contains CJK (Chinese, Japanese, Korean) characters
    /// These languages don't use inter-word spacing
    private func containsCJKCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if isCJKScalar(scalar) {
                return true
            }
        }
        return false
    }

    /// Check if a unicode scalar is in CJK range
    private func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // CJK Unified Ideographs: U+4E00-U+9FFF
        // CJK Extension A: U+3400-U+4DBF
        // Hiragana: U+3040-U+309F
        // Katakana: U+30A0-U+30FF
        // Hangul Syllables: U+AC00-U+D7AF
        // Katakana Phonetic Extensions: U+31F0-U+31FF
        // CJK Punctuation: U+3000-U+303F (includes 。、etc.)
        return (0x4E00...0x9FFF).contains(value) ||
               (0x3400...0x4DBF).contains(value) ||
               (0x3040...0x309F).contains(value) ||
               (0x30A0...0x30FF).contains(value) ||
               (0xAC00...0xD7AF).contains(value) ||
               (0x31F0...0x31FF).contains(value) ||
               (0x3000...0x303F).contains(value)
    }

    nonisolated private func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let int16Data = buffer.int16ChannelData else { return Data() }
        let frameLength = Int(buffer.frameLength)
        return Data(bytes: int16Data[0], count: frameLength * 2)
    }

    nonisolated private func convertFloatBufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
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

// MARK: - URLSessionWebSocketDelegate

extension GeminiRealtimeSTT: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        #if DEBUG
        print("GeminiRealtimeSTT: WebSocket didOpen")
        #endif

        // Delegate is called on main queue (OperationQueue.main)
        MainActor.assumeIsolated {
            self.isWebSocketConnected = true
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        #if DEBUG
        print("GeminiRealtimeSTT: WebSocket didClose with code: \(closeCode.rawValue), reason: \(reasonString)")
        #endif

        MainActor.assumeIsolated {
            self.isWebSocketConnected = false
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            #if DEBUG
            print("GeminiRealtimeSTT: URLSession task completed with error: \(error)")
            #endif
        }
    }
}
