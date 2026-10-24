import Foundation
@preconcurrency import AVFoundation

/// Grok dedicated Speech-to-Text streaming via WebSocket (`wss://api.x.ai/v1/stt`).
///
/// xAI provides a transcription-only WebSocket endpoint distinct from the Voice Agent.
/// Configuration is via URL query parameters (sample_rate, encoding, interim_results,
/// endpointing, language). Audio is sent as raw binary frames (PCM 16-bit mono). The
/// server emits `transcript.created` (ready), `transcript.partial` (interim or finalized
/// segments via `is_final`), `transcript.done` (final after `audio.done`), and `error`.
@MainActor
final class GrokRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "grok-stt"
    var selectedLanguage: String = ""  // "" = Auto (omit query param → server auto-detects)

    /// xAI STT language codes that are known to silently stall on the server side.
    /// When `selectedLanguage` matches one of these we omit the `language=` query
    /// param and let the server auto-detect, which works correctly. Other supported
    /// codes are forwarded as-is to give the recognizer a hint and improve accuracy.
    /// Verified broken (2026-04-27): ja. Add additional codes here if discovered.
    private static let knownBrokenLanguageCodes: Set<String> = ["ja"]
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    // VAD settings (kept for protocol compatibility; xAI server handles endpointing)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 0.5

    private var audioEngine: AVAudioEngine?
    private var configurationObserver: AudioEngineConfigurationObserver?
    private var webSocketTask: URLSessionWebSocketTask?
    private var finishingWebSocketTask: URLSessionWebSocketTask?
    private var connectionGeneration = UUID()
    private var finalizationTask: Task<Void, Never>?
    private var urlSession: URLSession?

    private let apiKeyManager = APIKeyManager.shared
    // 24kHz int16 mono — within xAI's supported 8–48kHz range.
    private let sampleRate: Double = 24000

    // Audio format converter for resampling
    private var audioConverter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // Accumulated transcription text. Finalized segments (is_final=true) append to
    // accumulatedText; the in-flight interim is held in currentPartialText.
    private var accumulatedText: String = ""
    private var currentPartialText: String = ""

    // Last finalized segment we appended to accumulatedText, identified by (start, text).
    // Used to dedupe the duplicate finalized partials xAI emits per utterance
    // (is_final=true, then speech_final=true with the same text).
    private var lastAccumulatedSegment: (start: Double, text: String)?

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

    // Set when the server emits `transcript.created` (ready to accept audio).
    private var serverReady = false

    // Set when the server emits `transcript.done` (final transcript after audio.done).
    // Used by stopListening to know when it can safely close the connection.
    private var transcriptDoneReceived = false

    // Auto-reconnect support
    private var isIntentionallyStopping = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3

    // Session generation token. Incremented on each startListening so the
    // deferred-close Task from a stopped session can detect that a new session
    // has started and avoid touching (or emitting from) the new session's state.
    private var sessionGeneration = 0

    func startListening() async throws {
        guard let apiKey = await apiKeyManager.apiKey(for: .grok) else {
            throw RealtimeSTTError.apiError(apiKeyManager.unavailableReason(for: .grok))
        }

        isIntentionallyStopping = false
        reconnectAttempts = 0

        // Stop any existing session
        stopListening()
        finishingWebSocketTask = nil

        // Invalidate any deferred-close Task still running for the old session
        sessionGeneration += 1

        // Reset state
        accumulatedText = ""
        currentPartialText = ""
        lastAccumulatedSegment = nil
        transcriptDoneReceived = false
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

        // Brief calibration period before connecting so the audio level monitor has
        // time to measure the noise floor. We connect AFTER this so that the URL
        // query string can include the adaptive endpointing value (xAI's STT
        // WebSocket does not allow re-configuring parameters post-connect).
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        try await connectWebSocket(apiKey: apiKey)

        // Flush pre-buffered audio as binary frames
        await flushPreBuffer()
    }

    func stopListening() {
        connectionGeneration = UUID()
        isIntentionallyStopping = true

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

        // Capture WebSocket handles for the deferred close. Setting the properties
        // to nil now lets a subsequent startListening create a fresh session without
        // waiting for the old one to finish closing.
        let task = webSocketTask
        finishingWebSocketTask = task
        let session = urlSession
        webSocketTask = nil
        urlSession = nil

        // Flip listening state immediately so the UI reflects "stopped" right away.
        let wasListening = isListening
        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }

        if wasListening, let task = task, task.state == .running {
            // Send audio.done and wait briefly for transcript.done before closing.
            // The server typically emits transcript.done within ~200–500ms; we cap
            // the wait at 1.5s to keep stop responsive even if the server stalls.
            // The final result is emitted after the wait so it includes the
            // server-authoritative full transcript when transcript.done arrives.
            transcriptDoneReceived = false
            let generation = sessionGeneration
            finalizationTask = Task { @MainActor [weak self] in
                if let jsonData = try? JSONSerialization.data(withJSONObject: ["type": "audio.done"]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    try? await task.send(.string(jsonString))
                }

                // Bail out of the wait early if a new session has started;
                // transcriptDoneReceived would then belong to the new session.
                let deadline = Date().addingTimeInterval(1.5)
                while let self = self,
                      self.sessionGeneration == generation,
                      !self.transcriptDoneReceived,
                      Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }

                task.cancel(with: .normalClosure, reason: nil)
                session?.invalidateAndCancel()

                // Emit only if this close still belongs to the current session;
                // otherwise accumulatedText was already reset by the new session.
                if let self = self, self.sessionGeneration == generation {
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
            RealtimeSTTModelInfo(id: "grok-stt", name: "Grok STT", description: "xAI dedicated streaming Speech-to-Text", isDefault: true)
        ]
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket(apiKey: String) async throws {
        // xAI dedicated STT WebSocket. Configuration is via query string;
        // there is no separate session.update message and no way to re-configure
        // post-connect, so adaptive parameters must be computed here.
        guard var components = URLComponents(string: "wss://api.x.ai/v1/stt") else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }
        // External audio (videos, etc.) tends to have continuous background sound;
        // shorten the silence window so segments finalize despite no real silence.
        let endpointingMs: Int = (audioSource == .external)
            ? 250
            : audioLevelMonitor.recommendedSilenceDuration()
        var items: [URLQueryItem] = [
            URLQueryItem(name: "sample_rate", value: String(Int(sampleRate))),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: String(endpointingMs))
        ]
        // Forward the language hint when supplied — improves recognition accuracy.
        // Skip codes known to silently stall the xAI server (see knownBrokenLanguageCodes);
        // auto-detect works for those. Empty string means user picked Auto.
        let langCode = selectedLanguage.lowercased()
        if !langCode.isEmpty && !Self.knownBrokenLanguageCodes.contains(langCode) {
            items.append(URLQueryItem(name: "language", value: langCode))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw RealtimeSTTError.apiError("Invalid WebSocket URL")
        }
        dprint("GrokRealtimeSTT: Connecting to \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: request)
        finishingWebSocketTask = nil
        webSocketTask = task
        serverReady = false
        task.resume()

        // Start receiving messages
        startReceivingMessages()

        // Wait for transcript.created event with timeout
        try await waitForServerReady(timeout: 5.0)
    }

    /// Wait for `transcript.created` from the server before sending audio.
    private func waitForServerReady(timeout: TimeInterval) async throws {
        let startTime = Date()
        while !serverReady {
            if webSocketTask == nil || webSocketTask?.state == .completed || webSocketTask?.state == .canceling {
                throw RealtimeSTTError.connectionError("WebSocket connection closed unexpectedly")
            }
            if Date().timeIntervalSince(startTime) > timeout {
                throw RealtimeSTTError.connectionError("Connection timeout: server did not respond within \(Int(timeout)) seconds")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #if DEBUG
        let elapsed = Date().timeIntervalSince(startTime)
        dprint("GrokRealtimeSTT: Server ready after \(String(format: "%.2f", elapsed))s")
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
                    self.apiKeyManager.noteHandshake(of: task, provider: .grok)
                    await MainActor.run {
                        guard self.acceptsMessages(from: task) else { return }
                        dprint("GrokRealtimeSTT: WebSocket receive error: \(error)")

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
        dprint("GrokRealtimeSTT: Reconnecting attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay)s")

        delegate?.realtimeSTT(self, didReceivePartialResult: "[Reconnecting...]")

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        serverReady = false

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard generation == connectionGeneration, isListening, !isIntentionallyStopping else { return }

        do {
            guard let apiKey = await apiKeyManager.apiKey(for: .grok) else {
                throw RealtimeSTTError.apiError(apiKeyManager.unavailableReason(for: .grok))
            }
            try await connectWebSocket(apiKey: apiKey)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            reconnectAttempts = 0
            dprint("GrokRealtimeSTT: Reconnected successfully")
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            dprint("GrokRealtimeSTT: Reconnect failed: \(error)")
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            dprint("GrokRealtimeSTT: Failed to parse message: \(jsonString.prefix(200))")
            return
        }

        #if DEBUG
        // Suppress verbose interim partials to keep logs readable.
        if eventType != "transcript.partial" {
            dprint("GrokRealtimeSTT: Received event: \(eventType)")
        }
        #endif

        switch eventType {
        case "transcript.created":
            // Server is ready to receive audio.
            serverReady = true

        case "transcript.partial":
            // xAI currently emits two finalized partials per utterance with the same text:
            //   1) is_final=true, speech_final=false — text recognition finalized
            //   2) is_final=true, speech_final=true  — utterance ended (~150ms later)
            // We accumulate on either signal and dedupe by (start, text), so we are
            // resilient to xAI dropping speech_final or sending only one of the two
            // events in a future revision. is_final=false events are treated as interim
            // preview (replace currentPartialText, do not append).
            let text = (json["text"] as? String) ?? ""
            let isFinal = (json["is_final"] as? Bool) ?? false
            let speechFinal = (json["speech_final"] as? Bool) ?? false
            let start = (json["start"] as? Double) ?? -1
            guard !text.isEmpty else { return }

            if isFinal || speechFinal {
                // Skip if this exact (start, text) was already appended by an earlier event.
                if let last = lastAccumulatedSegment, last.start == start && last.text == text {
                    return
                }
                if accumulatedText.isEmpty {
                    accumulatedText = text
                } else {
                    accumulatedText += " " + text
                }
                currentPartialText = ""
                lastAccumulatedSegment = (start, text)
                delegate?.realtimeSTT(self, didReceivePartialResult: accumulatedText)
            } else {
                currentPartialText = text
                let display = accumulatedText.isEmpty ? text : accumulatedText + " " + text
                delegate?.realtimeSTT(self, didReceivePartialResult: display)
            }

        case "transcript.done":
            // Final transcript after audio.done. Use the full text as authoritative.
            if let fullText = json["text"] as? String, !fullText.isEmpty {
                accumulatedText = fullText
                currentPartialText = ""
                delegate?.realtimeSTT(self, didReceivePartialResult: accumulatedText)
            }
            transcriptDoneReceived = true

        case "error":
            let errorMessage = (json["message"] as? String) ?? "Unknown error"
            dprint("GrokRealtimeSTT: Error: \(errorMessage)")
            delegate?.realtimeSTT(self, didFailWithError: RealtimeSTTError.apiError(errorMessage))

        default:
            #if DEBUG
            dprint("GrokRealtimeSTT: Unhandled event type: \(eventType)")
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

        // Prepare output format (24kHz, mono, 16-bit PCM)
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

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputFrameCapacity) else {
            return Data()
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
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
        let buffersToFlush = preBufferLock.withLock {
            let buffers = preBuffer
            preBuffer.removeAll()
            isPreBuffering = false
            return buffers
        }
        dprint("GrokRealtimeSTT: Flushing \(buffersToFlush.count) pre-buffered audio chunks")

        for data in buffersToFlush {
            sendAudioData(data)
            // Small delay to avoid overwhelming the WebSocket
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }

    private func sendAudioData(_ pcmData: Data) {
        guard let webSocketTask = webSocketTask else { return }

        // xAI STT expects raw audio as binary WebSocket frames (no JSON wrapper, no base64).
        webSocketTask.send(.data(pcmData)) { error in
            if let error = error {
                dprint("GrokRealtimeSTT: Send error: \(error)")
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

}
