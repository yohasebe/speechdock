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
    private var finishingWebSocketTask: URLSessionWebSocketTask?
    private var connectionGeneration = UUID()
    private var finalResponseReceived = false
    private var urlSession: URLSession?

    private let apiKeyManager = APIKeyManager.shared
    private let sampleRate: Double = 16000

    // Audio format converter for resampling
    private var audioConverter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // Accumulated committed text (ElevenLabs resets partial transcripts after each commit)
    private var committedText: String = ""
    // Decides which committed events add a new segment (see CommittedSegmentCounter)
    private var committedSegments = CommittedSegmentCounter()
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
        guard let apiKey = await apiKeyManager.apiKey(for: .elevenLabs) else {
            throw RealtimeSTTError.apiError(apiKeyManager.unavailableReason(for: .elevenLabs))
        }

        // Stop any existing session
        stopListening()
        finishingWebSocketTask = nil

        isIntentionallyStopping = false
        reconnectAttempts = 0

        // Reset accumulated text
        committedText = ""
        committedSegments = CommittedSegmentCounter()
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

    func finishListening() async {
        guard isListening, let task = webSocketTask else { stopListening(); return }
        let generation = connectionGeneration
        isIntentionallyStopping = true
        isListening = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        finalResponseReceived = false
        let message: [String: Any] = ["message_type": "input_audio_chunk", "audio_base_64": "", "commit": true, "sample_rate": 16000]
        if let data = try? JSONSerialization.data(withJSONObject: message),
           let text = String(data: data, encoding: .utf8) {
            try? await task.send(.string(text))
        }
        let deadline = Date().addingTimeInterval(1.5)
        while !finalResponseReceived, generation == connectionGeneration, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard generation == connectionGeneration else { return }
        stopListening()
    }

    func stopListening() {
        connectionGeneration = UUID()
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
        let pcmData = convertBufferToPCMData(buffer, converter: audioConverter, outFormat: outputFormat)
        sendPCMData(pcmData)
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        // Map old model IDs to realtime versions
        var model = selectedModel.isEmpty ? defaultModelId : selectedModel
        if model == "scribe_v2" || model == "scribe_v1" {
            model = "scribe_v2_realtime"
        }

        // ElevenLabs replaced the old `sample_rate` + `encoding` query params with
        // a unified `audio_format` (e.g. `pcm_16000`, `pcm_8000`, `ulaw_8000`).
        // The old params were silently ignored by the server in some recent
        // deployments; switching here keeps the connection forward-compatible.
        let audioFormat: String
        switch Int(sampleRate) {
        case 8000:  audioFormat = "pcm_8000"
        case 16000: audioFormat = "pcm_16000"
        case 24000: audioFormat = "pcm_24000"
        case 44100: audioFormat = "pcm_44100"
        case 48000: audioFormat = "pcm_48000"
        default:    audioFormat = "pcm_16000"  // safe fallback matching our sampleRate=16000
        }

        // Pin commit_strategy=vad explicitly. We never send manual commit messages,
        // yet the server emits committed_transcript events — i.e. we depend on
        // server-side VAD commits. Pinning the strategy locks that in instead of
        // relying on an ambiguous default, and lets us tune the silence threshold:
        // the API default of 1.5 s makes subtitles finalize noticeably later than
        // our other providers (~0.3–0.8 s). External audio (videos with BGM) gets
        // a shorter threshold since true silence is rare there.
        let vadSilenceSecs = (audioSource == .external) ? "0.5" : "0.8"

        guard var urlComponents = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime") else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }
        urlComponents.queryItems = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: audioFormat),
            URLQueryItem(name: "include_language_detection", value: "true"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: vadSilenceSecs)
        ]

        // Add language if specified (recommended for better accuracy)
        if !selectedLanguage.isEmpty {
            urlComponents.queryItems?.append(URLQueryItem(name: "language_code", value: selectedLanguage))
        }

        guard let url = urlComponents.url else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }
        dprint("ElevenLabsRealtimeSTT: Connecting to \(url.absoluteString)")
        dprint("ElevenLabsRealtimeSTT: Language code = '\(selectedLanguage)' (empty = auto-detect)")


        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: request)
        finishingWebSocketTask = nil
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
        dprint("ElevenLabsRealtimeSTT: Session started after \(String(format: "%.2f", elapsed))s")
        #endif
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
                    self.apiKeyManager.noteHandshake(of: task, provider: .elevenLabs)
                    await MainActor.run {
                        guard self.acceptsMessages(from: task) else { return }
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
        dprint("ElevenLabsRealtimeSTT: Reconnecting attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay)s")


        delegate?.realtimeSTT(self, didReceivePartialResult: "[Reconnecting...]")

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionStarted = false

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard generation == connectionGeneration, isListening, !isIntentionallyStopping else { return }

        do {
            guard let apiKey = await apiKeyManager.apiKey(for: .elevenLabs) else {
                throw RealtimeSTTError.apiError(apiKeyManager.unavailableReason(for: .elevenLabs))
            }
            try await connectWebSocket(apiKey: apiKey)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            reconnectAttempts = 0
            dprint("ElevenLabsRealtimeSTT: Reconnected successfully")

        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            dprint("ElevenLabsRealtimeSTT: Reconnect failed: \(error)")

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

    func parseTranscriptionMessage(_ jsonString: String) {  // internal for tests
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String else {
            dprint("ElevenLabsRealtimeSTT: Failed to parse message: \(jsonString.prefix(200))")

            return
        }

        switch messageType {
        case "session_started":
            sessionStarted = true
            dprint("ElevenLabsRealtimeSTT: Session started")


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
            // A segment may arrive twice, as committed_transcript and as
            // committed_transcript_with_timestamps (possibly after the next
            // segment's partial). The second copy changes nothing: not the text,
            // not the partial in progress, not the stop wait. Judged by event
            // counts, not text, so a phrase spoken again is kept.
            guard committedSegments.isNewSegment(messageType: messageType) else {
                dprint("ElevenLabsRealtimeSTT: Skipped second copy of a committed segment")
                return
            }
            finalResponseReceived = true
            if let text = json["text"] as? String, !text.isEmpty {
                #if DEBUG
                // Log detected language for debugging
                if let detectedLang = json["language_code"] as? String {
                    dprint("ElevenLabsRealtimeSTT: Detected language = '\(detectedLang)', text = '\(text.prefix(50))...'")
                }
                dprint("ElevenLabsRealtimeSTT: Committed text received: '\(text.prefix(100))...'")
                dprint("ElevenLabsRealtimeSTT: Current committedText: '\(committedText.suffix(100))...'")
                #endif

                committedText = committedText.isEmpty ? text : committedText + " " + text

                // Clear partial text since it's now committed
                currentPartialText = ""
                // Show accumulated text as partial result (final is only sent when stopping)
                delegate?.realtimeSTT(self, didReceivePartialResult: committedText)
            }

        case "error",
             "auth_error", "quota_exceeded", "rate_limited",
             "queue_overflow", "resource_exhausted",
             "session_time_limit_exceeded", "chunk_size_exceeded",
             "transcriber_error", "input_error", "unaccepted_terms":
            // Fatal — surface to user and stop. These were previously silently
            // dropped via `default: break` despite being real failure signals.
            let errorMessage = json["error"] as? String
                ?? json["message"] as? String
                ?? "ElevenLabs STT: \(messageType)"
            dprint("ElevenLabsRealtimeSTT: Fatal event \(messageType) — \(errorMessage)")
            delegate?.realtimeSTT(self, didFailWithError: RealtimeSTTError.apiError(errorMessage))
            stopListening()

        case "insufficient_audio_activity", "commit_throttled":
            // Non-fatal advisory events. Log so we can see them in the dev console
            // but don't disrupt the recording — these typically self-resolve as
            // more audio arrives.
            dprint("ElevenLabsRealtimeSTT: advisory \(messageType): \(jsonString.prefix(200))")

        default:
            #if DEBUG
            dprint("ElevenLabsRealtimeSTT: Unhandled event type: \(messageType)")
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

        // Prepare output format (16kHz, mono, 16-bit PCM)
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Extract samples for level monitoring
            var samples: [Float]?
            if let channelData = buffer.floatChannelData {
                let frameLength = Int(buffer.frameLength)
                samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            }

            // Convert audio data with resampling (can be done on background thread)
            let pcmData = self.convertBufferToPCMData(buffer, converter: capturedConverter, outFormat: capturedFormat)

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
    nonisolated private func convertBufferToPCMData(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter?, outFormat: AVAudioFormat?) -> Data {
        if let converter = converter, let outFormat = outFormat {
            // Need to convert format
            let ratio = outFormat.sampleRate / buffer.format.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputFrameCapacity) else {
                dprint("ElevenLabsRealtimeSTT: Failed to create output buffer (capacity: \(outputFrameCapacity))")

                return Data()
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .error || error != nil {
                dprint("ElevenLabsRealtimeSTT: Audio conversion failed - status: \(status.rawValue), error: \(error?.localizedDescription ?? "none")")

                return Data()
            }

            return bufferToData(outputBuffer)
        } else if buffer.format.commonFormat == .pcmFormatInt16 {
            // Already in correct format
            return bufferToData(buffer)
        } else {
            // Convert float to int16
            return convertFloatBufferToInt16Data(buffer)
        }
    }

    /// Send PCM data - must be called from main thread
    private func sendPCMData(_ pcmData: Data) {
        guard isListening, let webSocketTask = webSocketTask else { return }

        if pcmData.isEmpty {
            dprint("ElevenLabsRealtimeSTT: Empty PCM data after conversion")

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
            dprint("ElevenLabsRealtimeSTT: Failed to serialize audio buffer message")

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

        return Data(bytes: &int16Data, count: frameLength * 2)
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: "scribe_v2_realtime", name: "Scribe v2 Realtime", description: "~150ms latency streaming", isDefault: true)
        ]
    }
}

/// ElevenLabs may report each committed segment twice: as `committed_transcript`
/// and, with language detection or timestamps on, as
/// `committed_transcript_with_timestamps`, possibly after the next segment's
/// plain event. An event adds a segment only when its kind has now been seen
/// more often than the other kind; otherwise it is the second copy of a
/// segment already added. When only one kind arrives, every event adds one.
struct CommittedSegmentCounter {
    private var plain = 0
    private var timestamped = 0

    mutating func isNewSegment(messageType: String) -> Bool {
        if messageType == "committed_transcript_with_timestamps" {
            timestamped += 1
            return timestamped > plain
        }
        plain += 1
        return plain > timestamped
    }
}
