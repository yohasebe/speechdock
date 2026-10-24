import Foundation
@preconcurrency import AVFoundation

/// Google Gemini Live API for true streaming speech-to-text via WebSocket
@MainActor
final class GeminiRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = GeminiRealtimeSTT.transcribeModelId
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    // VAD auto-stop settings (Gemini has built-in VAD)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 3.0

    private var audioEngine: AVAudioEngine?
    private var configurationObserver: AudioEngineConfigurationObserver?
    private var webSocketTask: URLSessionWebSocketTask?
    private var finishingWebSocketTask: URLSessionWebSocketTask?
    private(set) var connectionGeneration = UUID()  // read by tests
    private var urlSession: URLSession?

    private let apiKeyManager = APIKeyManager.shared
    // Gemini Live API uses 16kHz audio
    private let sampleRate: Double = 16000

    // Audio format converter for resampling
    private var audioConverter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // Accumulated transcription text
    private var accumulatedText: String = ""
    /// The transcribe model's speculative text for the segment in progress.
    /// Replaced by each interim update and cleared when the segment is finalized.
    private var pendingInterimText: String = ""
    /// How long a stop keeps receiving after the end of audio. Nothing signals
    /// that the last input transcription has arrived, so the whole interval is used.
    static let stopGraceInterval: TimeInterval = 1.5

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
        guard let apiKey = await apiKeyManager.apiKey(for: .gemini) else {
            throw RealtimeSTTError.apiError(apiKeyManager.unavailableReason(for: .gemini))
        }

        // Stop any existing session
        stopListening()
        finishingWebSocketTask = nil

        isIntentionallyStopping = false
        reconnectAttempts = 0

        // Reset state
        accumulatedText = ""
        pendingInterimText = ""
        isSetupComplete = false
        isWebSocketConnected = false
        audioStartTime = nil
        preBufferLock.withLock {
            preBuffer.removeAll()
            isPreBuffering = true
        }

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

            // Wait for setup complete (audio stays in pre-buffer until then)
            try await waitForSetupComplete()

            // Flush pre-buffered audio
            await flushPreBuffer()
        } catch {
            // Clean up on error
            dprint("GeminiRealtimeSTT: startListening failed: \(error)")

            stopListening()
            throw error
        }
    }

    func finishListening() async {
        guard isListening, let task = webSocketTask else { stopListening(); return }
        let generation = connectionGeneration
        isIntentionallyStopping = true
        isListening = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        configurationObserver = nil
        audioEngine = nil
        let message: [String: Any] = ["realtimeInput": ["audioStreamEnd": true]]
        if let data = try? JSONSerialization.data(withJSONObject: message),
           let text = String(data: data, encoding: .utf8) {
            try? await task.send(.string(text))
        }
        await receiveUntilStopGraceEnds(generation: generation)
    }

    /// Keeps receiving for the stop grace interval, then closes the connection
    /// unless it was stopped or replaced meanwhile. Input transcription is not
    /// ordered with turnComplete and has no completion signal, so a quiet period
    /// does not mean the last audio has been transcribed.
    /// `now` and `sleep` are replaceable for tests.
    func receiveUntilStopGraceEnds(
        generation: UUID,
        now: @MainActor () -> Date = { Date() },
        sleep: @MainActor (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) async {
        let deadline = now().addingTimeInterval(Self.stopGraceInterval)
        while generation == connectionGeneration, now() < deadline, !Task.isCancelled {
            await sleep(25_000_000)
        }
        guard generation == connectionGeneration else { return }
        stopListening()
    }

    func stopListening() {
        connectionGeneration = UUID()
        isIntentionallyStopping = true
        dprint("GeminiRealtimeSTT: stopListening called, isListening=\(isListening)")


        // Stop audio engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        configurationObserver = nil
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

        // Send final result if there's any text. An interim tail that never
        // got its final segment is kept as shown rather than silently dropped.
        let finalText = textIncludingInterim
        pendingInterimText = ""
        if !finalText.isEmpty {
            delegate?.realtimeSTT(self, didReceiveFinalResult: finalText)
        }

        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }

        isSetupComplete = false
        dprint("GeminiRealtimeSTT: stopListening completed")

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

    /// The speech-to-text Live model. Unlike voice models it answers in TEXT,
    /// sends speculative `interimInputTranscription` while the speaker talks,
    /// and a finalized `inputTranscription` segment when speech settles.
    static let transcribeModelId = "gemini-3.5-transcribe-live"

    private var usesTranscribeModel: Bool {
        (selectedModel.isEmpty ? defaultModelId : selectedModel) == Self.transcribeModelId
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: Self.transcribeModelId, name: "Gemini 3.5 Transcribe Live", description: "Streaming speech-to-text", isDefault: true),
            RealtimeSTTModelInfo(id: "gemini-3.8-live", name: "Gemini 3.8 Live", description: "Voice model; transcribes its audio input")
        ]
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        // Gemini Live API WebSocket endpoint (using v1beta)
        guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)") else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }
        dprint("GeminiRealtimeSTT: Connecting to WebSocket...")


        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300

        // Use OperationQueue.main for delegate callbacks to avoid threading issues
        let session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
        urlSession = session

        let task = session.webSocketTask(with: url)
        finishingWebSocketTask = nil
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
        dprint("GeminiRealtimeSTT: WebSocket connected")

    }

    /// Wait for setupComplete from the server with timeout.
    /// Audio is kept in the pre-buffer while waiting so nothing is dropped
    /// if the server takes longer than expected to acknowledge setup.
    private func waitForSetupComplete(timeout: TimeInterval = 10.0) async throws {
        let startTime = Date()

        while !isSetupComplete {
            if Date().timeIntervalSince(startTime) > timeout {
                throw RealtimeSTTError.apiError("Setup complete timeout")
            }
            try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
        }
        dprint("GeminiRealtimeSTT: Setup complete confirmed, flushing pre-buffer")

    }

    private func sendSetupMessage() async throws {
        let model = selectedModel.isEmpty ? defaultModelId : selectedModel

        // System instruction for proper transcription formatting
        // Japanese/Chinese/Korean don't use inter-word spacing
        let systemInstructionText = """
            You are a speech transcription assistant. When transcribing audio:
            - For Japanese, Chinese, or Korean: Do NOT insert spaces between words or morphemes. Output natural text without spaces.
            - For English and other Western languages: Use normal word spacing.
            - Output only the transcription, no explanations.
            """

        let setup: [String: Any]
        if usesTranscribeModel {
            // Speech-to-text model: TEXT modality; the transcription config
            // carries the language (BCP-47; empty list = auto-detect).
            var transcription: [String: Any] = [:]
            if !selectedLanguage.isEmpty {
                transcription["languageCodes"] = [selectedLanguage]
            }
            setup = [
                "setup": [
                    "model": "models/\(model)",
                    "generationConfig": ["responseModalities": ["TEXT"]],
                    "inputAudioTranscription": transcription
                ]
            ]
        } else {
            // Voice model: AUDIO modality with input transcription enabled
            setup = [
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
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: setup),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw RealtimeSTTError.apiError("Failed to serialize setup message")
        }
        dprint("GeminiRealtimeSTT: Sending setup: \(jsonString)")


        try await webSocketTask?.send(.string(jsonString))
    }

    private func acceptsMessages(from task: URLSessionWebSocketTask) -> Bool {
        task === webSocketTask || task === finishingWebSocketTask
    }

    private func startReceivingMessages() {
        guard let task = webSocketTask else { return }
        Task { [weak self] in
            while let self, self.acceptsMessages(from: task), task.state == .running {
                do {
                    let message = try await task.receive()
                    guard self.acceptsMessages(from: task) else { return }
                    await MainActor.run {
                        guard self.acceptsMessages(from: task) else { return }
                        self.handleWebSocketMessage(message)
                    }
                } catch {
                    self.apiKeyManager.noteHandshake(of: task, provider: .gemini)
                    await MainActor.run {
                        guard self.acceptsMessages(from: task) else { return }
                        dprint("GeminiRealtimeSTT: WebSocket receive error: \(error)")

                        if self.isListening && !self.isIntentionallyStopping {
                            let generation = self.connectionGeneration
                            Task {
                                guard generation == self.connectionGeneration else { return }
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
        let generation = connectionGeneration
        // The old connection's interim text will not be finalized by the next one.
        keepInterimAcrossConnection()
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
        dprint("GeminiRealtimeSTT: Reconnecting attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay)s")


        delegate?.realtimeSTT(self, didReceivePartialResult: "[Reconnecting...]")

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isWebSocketConnected = false
        isSetupComplete = false

        // Keep audio in pre-buffer until the new session's setup completes
        preBufferLock.withLock {
            isPreBuffering = true
        }

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard generation == connectionGeneration, isListening, !isIntentionallyStopping else { return }

        do {
            guard let apiKey = await apiKeyManager.apiKey(for: .gemini) else {
                throw RealtimeSTTError.apiError(apiKeyManager.unavailableReason(for: .gemini))
            }
            try await connectWebSocket(apiKey: apiKey)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            try await sendSetupMessage()
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            try await waitForSetupComplete()
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            await flushPreBuffer()
            reconnectAttempts = 0
            dprint("GeminiRealtimeSTT: Reconnected successfully")

        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            dprint("GeminiRealtimeSTT: Reconnect failed: \(error)")

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

    func parseMessage(_ jsonString: String) {  // internal for tests
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            dprint("GeminiRealtimeSTT: Failed to parse message: \(jsonString.prefix(200))")

            return
        }

        #if DEBUG
        // Log full message for debugging
        dprint("GeminiRealtimeSTT: Received message: \(jsonString.prefix(500))")
        #endif

        // Check for setup complete
        if json["setupComplete"] != nil {
            isSetupComplete = true
            dprint("GeminiRealtimeSTT: Setup complete")

            return
        }

        // Check for input transcription at top level
        if let inputTranscription = json["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String, !text.isEmpty {
            receiveFinalTranscription(text)
            return
        }

        // Check for server content (transcription may be nested here)
        if let serverContent = json["serverContent"] as? [String: Any] {
            dprint("GeminiRealtimeSTT: serverContent keys: \(serverContent.keys)")


            // Finalized input transcription: replaces the interim text of its segment.
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String, !text.isEmpty {
                receiveFinalTranscription(text)
            }
            // Speculative text for the segment in progress (transcribe model),
            // handled independently: a message may carry both.
            if let interim = serverContent["interimInputTranscription"] as? [String: Any],
               let text = interim["text"] as? String {
                pendingInterimText = text
                delegate?.realtimeSTT(self, didReceivePartialResult: textIncludingInterim)
            }

            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                dprint("GeminiRealtimeSTT: Turn complete")

            }
            return
        }

        // Check for errors
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            dprint("GeminiRealtimeSTT: Error: \(message)")

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
        configurationObserver = AudioEngineConfigurationObserver(engine: audioEngine) { [weak self] in
            self?.stopAfterAudioConfigurationChange(of: self?.audioEngine)
        }
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
            dprint("GeminiRealtimeSTT: Audio conversion error: \(error?.localizedDescription ?? "unknown")")

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
        let buffersToFlush = preBufferLock.withLock {
            let buffers = preBuffer
            preBuffer.removeAll()
            isPreBuffering = false
            return buffers
        }
        dprint("GeminiRealtimeSTT: Flushing \(buffersToFlush.count) pre-buffered audio chunks")


        for data in buffersToFlush {
            sendAudioData(data)
            // Small delay to avoid overwhelming the WebSocket
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }

    private func sendAudioData(_ pcmData: Data) {
        guard let webSocketTask = webSocketTask, isSetupComplete else { return }

        // Send as base64 encoded audio via realtimeInput.audio (the legacy
        // realtimeInput.mediaChunks form is rejected by gemini-3.1-flash-live-preview
        // with: "realtime_input.media_chunks is deprecated. Use audio, video, or text instead.")
        let base64Audio = pcmData.base64EncodedString()

        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": base64Audio
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            dprint("GeminiRealtimeSTT: Failed to serialize audio buffer message")

            return
        }

        webSocketTask.send(.string(jsonString)) { error in
            if let error = error {
                dprint("GeminiRealtimeSTT: Send error: \(error)")

            }
        }
    }

    /// Append transcription text - Gemini sends incremental fragments
    /// A finalized segment: appended, replacing the interim text of its segment.
    private func receiveFinalTranscription(_ text: String) {
        appendTranscriptionText(text)
        pendingInterimText = ""
        dprint("GeminiRealtimeSTT: Transcription: '\(text)'")
        delegate?.realtimeSTT(self, didReceivePartialResult: accumulatedText)
    }

    /// Keeps the interim text shown before a connection ends as finalized text.
    /// A new connection's segments are new audio and must not replace it.
    func keepInterimAcrossConnection() {  // internal for tests
        accumulatedText = textIncludingInterim
        pendingInterimText = ""
    }

    /// Finalized text followed by the pending interim text, if any.
    private var textIncludingInterim: String {
        guard !pendingInterimText.isEmpty else { return accumulatedText }
        return accumulatedText + joinedFragment(pendingInterimText, after: accumulatedText, wholeSegment: true)
    }

    private func appendTranscriptionText(_ newText: String) {
        guard !newText.isEmpty else { return }

        #if DEBUG
        let debugText = newText.replacingOccurrences(of: " ", with: "␣")
        dprint("GeminiRealtimeSTT: appendTranscriptionText")
        dprint("  - newText (raw): '\(debugText)'")
        dprint("  - accumulatedText before: '\(accumulatedText.suffix(80))'")
        #endif

        let processedText = joinedFragment(newText, after: accumulatedText, wholeSegment: usesTranscribeModel)

        // Skip if processed text is empty (was just whitespace)
        guard !processedText.isEmpty else { return }

        accumulatedText += processedText
        dprint("  - processedText: '\(processedText)'")
        dprint("  - accumulatedText after: '\(accumulatedText.suffix(80))'")

    }

    /// `newText` as it should be appended to `existing`. CJK text carries no
    /// inter-word spaces. Voice models send fragments that bring their own
    /// leading space; whole segments (the transcribe model's finals, and any
    /// interim text) get a space between two non-CJK segments.
    private func joinedFragment(_ newText: String, after existing: String, wholeSegment: Bool) -> String {
        var processedText = newText

        // Check if we're in CJK context (accumulated text ends with CJK or new text contains CJK)
        let lastCharIsCJK = existing.last.map { isCJKCharacter($0) } ?? false
        let newTextHasCJK = containsCJKCharacters(newText)

        if newTextHasCJK {
            // New text contains CJK - remove all spaces
            processedText = newText.replacingOccurrences(of: " ", with: "")
        } else if lastCharIsCJK {
            // Previous text ended with CJK - remove leading spaces from this fragment
            // This handles cases where Gemini sends " " as a separate fragment
            processedText = newText.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        } else if wholeSegment, let last = existing.last, !last.isWhitespace,
                  let first = processedText.first, !first.isWhitespace {
            processedText = " " + processedText
        }
        return processedText
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
        dprint("GeminiRealtimeSTT: WebSocket didOpen")


        // Delegate is called on main queue (OperationQueue.main)
        MainActor.assumeIsolated {
            guard self.webSocketTask === webSocketTask else { return }
            self.isWebSocketConnected = true
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        dprint("GeminiRealtimeSTT: WebSocket didClose with code: \(closeCode.rawValue), reason: \(reasonString)")


        MainActor.assumeIsolated {
            guard self.webSocketTask === webSocketTask else { return }
            self.isWebSocketConnected = false
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            dprint("GeminiRealtimeSTT: URLSession task completed with error: \(error)")

        }
    }
}
