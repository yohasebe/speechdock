import Foundation
@preconcurrency import AVFoundation

/// OpenAI Realtime API for true streaming speech-to-text via WebSocket.
///
/// Uses the GA `?intent=transcription` endpoint with `session.update` +
/// `session.type: "transcription"`. Two operating modes depending on model:
///
/// * `gpt-realtime-whisper` (default): emits continuous `.delta` events for live
///   partial transcripts. Server VAD is unsupported — we run client-side VAD on
///   `audioLevelMonitor` and send `input_audio_buffer.commit` when speech ends, which
///   triggers `.completed` with the finalized segment.
/// * `gpt-live-transcribe` / `gpt-transcribe`: also driven by client-side commit
///   (no server VAD: `turn_detection: null`), with language hints as `languages`.
///   Live Transcribe streams deltas as speech arrives; Transcribe starts after
///   each committed turn.
@MainActor
final class OpenAIRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "gpt-realtime-whisper"
    var selectedLanguage: String = ""  // "" = Auto (OpenAI auto-detects)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    // VAD settings for turn detection
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 0.5  // 500ms

    private var audioEngine: AVAudioEngine?
    private var configurationObserver: AudioEngineConfigurationObserver?
    private var webSocketTask: URLSessionWebSocketTask?
    private var finishingWebSocketTask: URLSessionWebSocketTask?
    private var connectionGeneration = UUID()
    private var finalizationTask: Task<Void, Never>?
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

    // Client-side VAD (used because none of the transcription models offered here
    // supports server VAD; the session needs a manual commit per turn).
    /// Last time an above-threshold audio sample was observed (since last commit).
    private var lastAudioActivityTime: Date?
    /// Time the first audio of the current unfinalized segment was observed.
    /// Used to force-commit long monologues that never hit silence.
    private var currentSegmentStartTime: Date?
    /// Whether audio has been sent since the most recent commit and needs flushing.
    private var hasUnfinalizedAudio = false
    /// Set after sendCommit; cleared when `.completed` arrives or after timeout.
    private var commitInFlight = false
    /// When commitInFlight was set. Used to recover from missing `.completed` events.
    private var commitInFlightStartTime: Date?
    /// Hard upper bound on a single segment without silence-triggered commit (60s).
    private let maxSegmentDuration: TimeInterval = 60.0
    /// Timeout after which commitInFlight auto-resets if `.completed` never arrives.
    private let commitInFlightTimeout: TimeInterval = 10.0

    // Auto-reconnect support
    private var isIntentionallyStopping = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    private var reconnectTask: Task<Void, Never>?

    // Session generation token, reissued on each startListening so deferred
    // tasks from a previous session don't touch the new session's state
    private var sessionGeneration = UUID()

    func startListening() async throws {
        guard let apiKey = await apiKeyManager.apiKey(for: .openAI) else {
            throw RealtimeSTTError.apiError(apiKeyManager.unavailableReason(for: .openAI))
        }

        // Stop any existing session
        stopListening()
        finishingWebSocketTask = nil

        // Start a new session generation so deferred tasks from the previous
        // session stop touching shared state
        sessionGeneration = UUID()

        // Reset reconnect state
        isIntentionallyStopping = false
        reconnectAttempts = 0

        // Reset state
        accumulatedText = ""
        currentPartialText = ""
        audioStartTime = nil
        lastAudioActivityTime = nil
        currentSegmentStartTime = nil
        hasUnfinalizedAudio = false
        commitInFlight = false
        commitInFlightStartTime = nil
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
        do {
            try await connectWebSocket(apiKey: apiKey)

            // Brief calibration period to measure noise floor (audio is being captured)
            // This allows adaptive VAD parameters based on background noise
            try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

            // Configure the transcription session with adaptive VAD parameters
            try await configureSession()

            // Flush pre-buffered audio
            await flushPreBuffer()
        } catch {
            // Clean up on failure so no reconnect task survives a thrown startListening
            dprint("OpenAIRealtimeSTT: startListening failed: \(error)")

            stopListening()
            throw error
        }
    }

    func stopListening() {
        connectionGeneration = UUID()
        isIntentionallyStopping = true

        // Cancel any pending reconnect so it can't revive a stopped session
        reconnectTask?.cancel()
        reconnectTask = nil

        // Stop audio engine immediately so we don't keep streaming after user stops
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

        // Capture WebSocket for the deferred close so subsequent state changes don't race.
        let task = webSocketTask
        finishingWebSocketTask = task
        let session = urlSession
        let needsFinalCommit = hasUnfinalizedAudio && !commitInFlight
        // If we'll send a final commit, mark so the wait loop knows to expect a
        // `.completed` event before closing.
        if needsFinalCommit {
            commitInFlight = true
            commitInFlightStartTime = Date()
        }
        webSocketTask = nil
        urlSession = nil

        // Flip listening state immediately so UI reflects "stopped" without waiting.
        let wasListening = isListening
        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }

        if wasListening, let task = task, task.state == .running {
            // Send a final commit so the server emits one last `.completed` with the
            // trailing utterance, then close after ~1.5s to capture it.
            // The generation token guards against a new session starting meanwhile:
            // shared state (commitInFlight, accumulatedText) belongs to the new
            // session then, so this deferred close must not read or mutate it.
            let generation = sessionGeneration
            finalizationTask = Task { @MainActor [weak self] in
                guard let self = self, self.sessionGeneration == generation else {
                    task.cancel(with: .normalClosure, reason: nil)
                    session?.invalidateAndCancel()
                    return
                }
                if needsFinalCommit {
                    if let jsonData = try? JSONSerialization.data(withJSONObject: ["type": "input_audio_buffer.commit"]),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        try? await task.send(.string(jsonString))
                    }
                }
                let deadline = Date().addingTimeInterval(1.5)
                while self.sessionGeneration == generation,
                      self.commitInFlight,
                      Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                task.cancel(with: .normalClosure, reason: nil)
                session?.invalidateAndCancel()
                if self.sessionGeneration == generation {
                    self.emitFinalResult()
                }
            }
        } else {
            session?.invalidateAndCancel()
            emitFinalResult()
        }
    }

    func finishListening() async {
        if isListening { stopListening() }
        await finalizationTask?.value
    }

    /// Emit didReceiveFinalResult with the current accumulatedText (+ trailing partial).
    private func emitFinalResult() {
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
            RealtimeSTTModelInfo(id: "gpt-realtime-whisper", name: "GPT Realtime Whisper", description: "Streaming deltas, lowest latency", isDefault: true),
            RealtimeSTTModelInfo(id: "gpt-live-transcribe", name: "GPT Live Transcribe", description: "Streaming deltas as speech arrives"),
            RealtimeSTTModelInfo(id: "gpt-transcribe", name: "GPT Transcribe", description: "Transcript after each pause")
        ]
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        // GA Realtime endpoint for transcription-only sessions. The URL's `?model=`
        // parameter only accepts conversation/realtime models (e.g. gpt-realtime-2);
        // passing a transcription-only model like gpt-realtime-whisper there is rejected
        // with: "Model … is a transcription model and cannot be used as the realtime
        // session model. … Pass this transcription model as audio.input.transcription.model
        // instead." So we use the transcription intent URL and supply the transcription
        // model inside session.update's `audio.input.transcription.model`.
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }
        dprint("OpenAIRealtimeSTT: Connecting to \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: request)
        finishingWebSocketTask = nil
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
        dprint("OpenAIRealtimeSTT: Session created after \(String(format: "%.2f", elapsed))s")
        #endif
    }

    private func configureSession() async throws {
        // Configure the transcription session using the GA session.update format.
        let model = selectedModel.isEmpty ? defaultModelId : selectedModel
        let isWhisperRealtime = model.hasPrefix("gpt-realtime-whisper")

        // GA Realtime API: nested `audio.input` shape under `session.type: "transcription"`.
        var transcriptionConfig: [String: Any] = ["model": model]
        if !selectedLanguage.isEmpty {
            // gpt-live-transcribe and gpt-transcribe take a list instead of `language`.
            transcriptionConfig[isWhisperRealtime ? "language" : "languages"] =
                isWhisperRealtime ? selectedLanguage as Any : [selectedLanguage]
        }

        // Noise reduction: near_field assumes a microphone close to the speaker;
        // far_field is tuned for distant or speaker-output sources (system audio).
        let noiseReductionType = (audioSource == .external) ? "far_field" : "near_field"
        var audioInput: [String: Any] = [
            "format": [
                "type": "audio/pcm",
                "rate": Int(sampleRate)
            ],
            "transcription": transcriptionConfig,
            "noise_reduction": ["type": noiseReductionType]
        ]

        // Turn detection handling:
        //   * gpt-realtime-whisper rejects ANY turn_detection value
        //     ("Turn detection is not supported for this transcription model").
        //     Omit the key entirely.
        //   * gpt-live-transcribe / gpt-transcribe: server VAD is not supported;
        //     the commit timing is ours. Send `null`.
        if !isWhisperRealtime {
            audioInput["turn_detection"] = NSNull()
        }
        dprint("OpenAIRealtimeSTT: Configuring session for model=\(model) (clientVAD)")

        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": audioInput
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw RealtimeSTTError.apiError("Failed to serialize session config")
        }
        dprint("OpenAIRealtimeSTT: Sending session config: \(jsonString)")


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
                    self.apiKeyManager.noteHandshake(of: task, provider: .openAI)
                    await MainActor.run {
                        guard self.acceptsMessages(from: task) else { return }
                        dprint("OpenAIRealtimeSTT: WebSocket receive error: \(error)")

                        if self.isListening && !self.isIntentionallyStopping {
                            let generation = self.connectionGeneration
                            self.reconnectTask = Task {
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
        // Only fire while actively listening on an unintended disconnection
        guard generation == connectionGeneration, isListening, !isIntentionallyStopping else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            // Send accumulated text before reporting error so it's not lost
            if !accumulatedText.isEmpty {
                delegate?.realtimeSTT(self, didReceivePartialResult: accumulatedText)
            }
            let error = RealtimeSTTError.connectionError("Connection lost after \(maxReconnectAttempts) reconnect attempts")
            delegate?.realtimeSTT(self, didFailWithError: error)
            return
        }
        reconnectAttempts += 1
        let delay = pow(2.0, Double(reconnectAttempts - 1))  // 1s, 2s, 4s
        dprint("OpenAIRealtimeSTT: Reconnecting attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay)s")


        delegate?.realtimeSTT(self, didReceivePartialResult: "[Reconnecting...]")

        // Close existing connection
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionCreated = false

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard generation == connectionGeneration, isListening, !isIntentionallyStopping, !Task.isCancelled else { return }

        do {
            guard let apiKey = await apiKeyManager.apiKey(for: .openAI) else {
                throw RealtimeSTTError.apiError(apiKeyManager.unavailableReason(for: .openAI))
            }
            try await connectWebSocket(apiKey: apiKey)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            try await configureSession()
            reconnectAttempts = 0  // Reset on successful reconnect
            dprint("OpenAIRealtimeSTT: Reconnected successfully")

        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            dprint("OpenAIRealtimeSTT: Reconnect failed: \(error)")

            await handleUnexpectedDisconnection()
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
                dprint("OpenAIRealtimeSTT: Failed to decode WebSocket data as string")
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
            dprint("OpenAIRealtimeSTT: Failed to parse message: \(jsonString.prefix(200))")

            return
        }

        #if DEBUG
        if eventType != "input_audio_buffer.speech_started" &&
           eventType != "input_audio_buffer.speech_stopped" {
            dprint("OpenAIRealtimeSTT: Received event: \(eventType)")
        }
        #endif

        switch eventType {
        case "session.created", "transcription_session.created":
            sessionCreated = true
            dprint("OpenAIRealtimeSTT: Session created")


        case "session.updated", "transcription_session.updated":
            dprint("OpenAIRealtimeSTT: Session updated")


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
                dprint("OpenAIRealtimeSTT: Delta text: '\(delta)'")

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
                dprint("OpenAIRealtimeSTT: Transcription completed: '\(transcript.prefix(50))...'")

            }
            // Segment finalized — allow client-side VAD to detect the next utterance.
            commitInFlight = false
            commitInFlightStartTime = nil

        case "input_audio_buffer.speech_started":
            dprint("OpenAIRealtimeSTT: Speech started")


        case "input_audio_buffer.speech_stopped":
            dprint("OpenAIRealtimeSTT: Speech stopped")


        case "input_audio_buffer.committed":
            dprint("OpenAIRealtimeSTT: Audio buffer committed")


        case "error":
            let errorMessage = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            dprint("OpenAIRealtimeSTT: Error: \(errorMessage)")

            delegate?.realtimeSTT(self, didFailWithError: RealtimeSTTError.apiError(errorMessage))

        default:
            #if DEBUG
            if !eventType.starts(with: "rate_limits") {
                dprint("OpenAIRealtimeSTT: Unhandled event type: \(eventType)")
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

        // Capture converter and format for use in tap closure. The tap runs on a
        // realtime audio render thread, so it must not touch MainActor state.
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

            // Convert PCM on the render thread (nonisolated, no shared state)
            let pcmData = self.convertBufferToData(buffer, converter: capturedConverter, outFormat: capturedFormat)

            // Everything that touches state (level monitor, isListening, settling
            // skip, preBuffer, sendAudioData, updateClientVAD) hops to main
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

    /// Convert buffer to PCM data with optional resampling.
    /// Parameters are passed explicitly so this can run on the audio render thread.
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

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputFrameCapacity) else {
            return Data()
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            return Data()
        }

        return bufferToData(outputBuffer)
    }

    /// Convert then dispatch an externally captured buffer (called on main thread)
    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isListening else { return }

        let pcmData = convertBufferToData(buffer, converter: audioConverter, outFormat: outputFormat)
        sendPCMData(pcmData)
    }

    /// Handle converted PCM data - must be called on the main thread
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
            updateClientVAD()
        }
    }

    /// Client-side VAD: track audio level vs. adaptive threshold. When silence
    /// exceeds the recommended duration after an utterance, send a manual
    /// `input_audio_buffer.commit` so the server finalizes a transcript segment.
    /// Also force-commits when a single segment exceeds `maxSegmentDuration` to
    /// keep buffer growth bounded during long monologues.
    /// (None of the offered transcription models supports server VAD.)
    private func updateClientVAD() {
        // Recover from a stuck commitInFlight if `.completed` was never received
        // (server stall, transient network error). Without this, the entire session
        // would silently stop emitting transcripts after one failed commit.
        if commitInFlight,
           let startTime = commitInFlightStartTime,
           Date().timeIntervalSince(startTime) > commitInFlightTimeout {
            dprint("OpenAIRealtimeSTT: commitInFlight timeout — resetting")
            commitInFlight = false
            commitInFlightStartTime = nil
        }

        let level = audioLevelMonitor.level
        let threshold = clientVADThreshold()
        let silenceMs = clientVADSilenceDurationMs()
        let now = Date()

        if level > threshold {
            // Speech detected — extend activity window. Continue tracking even
            // during commitInFlight so we don't miss a new utterance starting
            // before `.completed` arrives.
            lastAudioActivityTime = now
            if currentSegmentStartTime == nil {
                currentSegmentStartTime = now
            }
            hasUnfinalizedAudio = true
        }

        // Don't attempt a new commit while one is in flight; the next one will
        // fire when `.completed` arrives (or after the timeout above).
        guard !commitInFlight else { return }

        // Silence-triggered commit.
        if hasUnfinalizedAudio,
           let lastTime = lastAudioActivityTime,
           now.timeIntervalSince(lastTime) * 1000 >= Double(silenceMs) {
            sendCommit(reason: "silence")
            return
        }

        // Max-segment-duration force-commit (long monologue without pauses).
        if hasUnfinalizedAudio,
           let segStart = currentSegmentStartTime,
           now.timeIntervalSince(segStart) >= maxSegmentDuration {
            sendCommit(reason: "max-duration")
            return
        }
    }

    /// Client VAD threshold. External audio (videos with BGM) needs a lower bar
    /// than microphone since true silence is rare.
    private func clientVADThreshold() -> Float {
        if audioSource == .external {
            return 0.25
        }
        return Float(audioLevelMonitor.recommendedVADThreshold())
    }

    /// Client VAD silence duration. Shorter for external audio so we finalize
    /// segments despite the lack of true silence.
    private func clientVADSilenceDurationMs() -> Int {
        if audioSource == .external {
            return 250
        }
        return audioLevelMonitor.recommendedSilenceDuration()
    }

    /// Tell the server to commit the current input audio buffer. Triggers
    /// `.completed` once the segment is transcribed.
    private func sendCommit(reason: String) {
        guard let task = webSocketTask, task.state == .running else { return }
        commitInFlight = true
        commitInFlightStartTime = Date()
        hasUnfinalizedAudio = false
        lastAudioActivityTime = nil
        currentSegmentStartTime = nil
        if let jsonData = try? JSONSerialization.data(withJSONObject: ["type": "input_audio_buffer.commit"]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            task.send(.string(jsonString)) { _ in }
        }
        dprint("OpenAIRealtimeSTT: Sent input_audio_buffer.commit (reason=\(reason))")
    }

    private func flushPreBuffer() async {
        let buffersToFlush = preBufferLock.withLock {
            let buffers = preBuffer
            preBuffer.removeAll()
            isPreBuffering = false
            return buffers
        }
        dprint("OpenAIRealtimeSTT: Flushing \(buffersToFlush.count) pre-buffered audio chunks")


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
            dprint("OpenAIRealtimeSTT: Failed to serialize audio buffer message")

            return
        }

        webSocketTask.send(.string(jsonString)) { error in
            if let error = error {
                dprint("OpenAIRealtimeSTT: Send error: \(error)")

            }
        }
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
