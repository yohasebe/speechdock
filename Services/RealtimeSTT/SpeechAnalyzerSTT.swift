import Foundation
import Speech
@preconcurrency import AVFoundation
// AVAudioPCMBuffer is attributed to the AVFAudio module in diagnostics, so the
// AVFoundation umbrella's @preconcurrency above doesn't cover it.
@preconcurrency import AVFAudio

// SpeechAnalyzer APIs are only available in macOS 26+ SDK (Xcode 17+)
// Use compile-time check to avoid errors on older SDKs
#if compiler(>=6.1)

// Debug logging helper
private func debugLog(_ message: String) {
    #if DEBUG
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    dprint("[\(timestamp)] \(message)")
    #endif
}

/// macOS 26+ speech recognition using SpeechAnalyzer
/// Provides real-time transcription without the ~1 minute limit of SFSpeechRecognizer
@available(macOS 26, *)
@MainActor
final class SpeechAnalyzerSTT: NSObject, RealtimeSTTService {
    // MARK: - RealtimeSTTService Protocol

    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = ""
    var selectedLanguage: String = ""  // "" = Auto (uses system locale)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    // VAD auto-stop settings (not used by SpeechAnalyzer, but required by protocol)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 3.0

    // MARK: - SpeechAnalyzer Components

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    // MARK: - Audio Components

    private var audioEngine: AVAudioEngine?
    private var configurationObserver: AudioEngineConfigurationObserver?

    // Serial audio buffer pipeline. The tap/processAudioBuffer enqueue buffers
    // into this stream and a single consumer task converts and forwards them to
    // the analyzer, so buffer order is guaranteed and conversion runs off the
    // main actor.
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var bufferTask: Task<Void, Never>?

    // MARK: - Pre-buffer for initial audio

    private var preBuffer: [AVAudioPCMBuffer] = []
    private var isPreBuffering = true
    private let preBufferLock = NSLock()
    private let maxPreBufferDuration: TimeInterval = 5.0  // Max seconds to pre-buffer

    // MARK: - State

    private var lastTranscription = ""
    private var accumulatedTranscription = ""  // Accumulated final transcriptions
    private var resultsTask: Task<Void, Never>?
    private let audioLevelMonitor = AudioLevelMonitor.shared
    private var startupGeneration = UUID()
    private var installationProgress: Progress?
    private var sessionID = 0  // Incremented per session to invalidate stale async work

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - RealtimeSTTService Methods

    func startListening() async throws {
        // Stop any existing session
        stopListening()
        sessionID &+= 1
        let startup = startupGeneration

        #if DEBUG
        let startTime = Date()
        debugLog("SpeechAnalyzerSTT: Starting setup...")
        #endif

        // Reset pre-buffer state
        preBufferLock.withLock {
            preBuffer.removeAll()
            isPreBuffering = true
        }

        delegate?.realtimeSTT(self, didUpdatePreparation: NSLocalizedString("Preparing speech recognition...", comment: "STT preparation"))

        // Create locale based on selected language
        // Note: macOS provider does not offer Auto — language is always explicitly set
        let locale: Locale
        if !selectedLanguage.isEmpty,
           let langCode = LanguageCode(rawValue: selectedLanguage),
           let localeId = langCode.toLocaleIdentifier() {
            locale = Locale(identifier: localeId)
        } else {
            // Fallback: should not reach here for macOS provider, but default to en-US
            locale = Locale(identifier: "en-US")
        }

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Creating transcriber for locale: \(locale.identifier)...")
        #endif

        // Initialize SpeechTranscriber for live transcription
        // Using reportingOptions: [.volatileResults, .fastResults] for fastest real-time results
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Transcriber created in \(Date().timeIntervalSince(startTime))s")
        #endif

        // Verify the locale is supported, then auto-download its language model if
        // missing. assetInstallationRequest(supporting:) returns nil when assets are
        // already installed, so the happy path costs one cheap inventory check.
        // Previously a missing model surfaced as an opaque start failure and users
        // had to discover the manual download path themselves.
        let supportedIds = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        try Task.checkCancellation()
        guard startupGeneration == startup else { throw CancellationError() }
        guard supportedIds.contains(locale.identifier(.bcp47)) else {
            throw RealtimeSTTError.serviceUnavailable(
                "Speech recognition for \(locale.identifier) is not supported on this system")
        }
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try Task.checkCancellation()
            guard startupGeneration == startup else { throw CancellationError() }
            debugLog("SpeechAnalyzerSTT: Language model for \(locale.identifier) missing — downloading...")
            installationProgress = installationRequest.progress
            let progressTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, self.startupGeneration == startup else { return }
                    let percent = Int(installationRequest.progress.fractionCompleted * 100)
                    self.delegate?.realtimeSTT(self, didUpdatePreparation: String(format: NSLocalizedString("Downloading language model: %d%%", comment: "STT model download"), percent))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            defer { progressTask.cancel(); installationProgress = nil }
            try await installationRequest.downloadAndInstall()
            debugLog("SpeechAnalyzerSTT: Language model installed")
        }

        try Task.checkCancellation()
        guard startupGeneration == startup else { throw CancellationError() }

        // Initialize SpeechAnalyzer with the transcriber module
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Get the best available audio format for the transcriber
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RealtimeSTTError.audioError("Failed to get analyzer audio format")
        }

        // Prewarm model resources before start — documented pattern to cut
        // first-result latency on a fresh session.
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try Task.checkCancellation()
        guard startupGeneration == startup else { throw CancellationError() }

        // Create AsyncStream for audio input
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Start the serial buffer pipeline
        let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.bufferContinuation = bufferContinuation
        bufferTask = Task.detached { [weak self] in
            await self?.runBufferPipeline(bufferStream, format: analyzerFormat, continuation: continuation)
        }

        // Start results monitoring task
        startResultsMonitoring()

        // Start the analyzer
        try await analyzer.start(inputSequence: inputSequence)

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Analyzer started, flushing pre-buffer...")
        #endif

        try Task.checkCancellation()
        guard startupGeneration == startup else { throw CancellationError() }
        if audioSource == .microphone { try await startAudioCapture() }
        try Task.checkCancellation()
        guard startupGeneration == startup else {
            audioEngine?.stop()
            throw CancellationError()
        }
        isListening = true
        audioLevelMonitor.start()
        delegate?.realtimeSTT(self, didUpdatePreparation: nil)
        delegate?.realtimeSTT(self, didChangeListeningState: true)

        // Flush pre-buffered audio to the analyzer
        await flushPreBuffer()

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Started listening with locale: \(locale.identifier) (total setup: \(Date().timeIntervalSince(startTime))s)")
        #endif
    }

    private var finalizationTask: Task<Void, Never>?

    func finishListening() async {
        if isListening { stopListening() }
        await finalizationTask?.value
    }

    func stopListening() {
        startupGeneration = UUID()
        installationProgress?.cancel()
        installationProgress = nil
        // Stop audio engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        configurationObserver = nil
        audioEngine = nil
        audioLevelMonitor.stop()

        // Clear pre-buffer
        preBufferLock.lock()
        preBuffer.removeAll()
        isPreBuffering = false
        preBufferLock.unlock()

        // Finish the buffer pipeline (enqueued buffers drain, then it terminates)
        bufferContinuation?.finish()
        bufferContinuation = nil
        let pipeline = bufferTask
        bufferTask = nil

        // Finish analyzer input after the queued audio buffers have drained.
        let continuation = inputContinuation
        inputContinuation = nil

        // Finalize the analyzer asynchronously (required by API). Finalize first
        // and let the results task drain the final segments produced by
        // finalization before cancelling it — cancelling first would lose them.
        let session = sessionID
        let analyzerToFinalize = analyzer
        let resultsTaskToFinish = resultsTask
        analyzer = nil
        transcriber = nil
        resultsTask = nil

        if let analyzerToFinalize = analyzerToFinalize {
            finalizationTask = Task { [weak self] in
                await pipeline?.value
                continuation?.finish()
                do {
                    try await analyzerToFinalize.finalizeAndFinishThroughEndOfInput()
                    // Wait for trailing results emitted by finalization
                    await resultsTaskToFinish?.value
                } catch {
                    #if DEBUG
                    debugLog("SpeechAnalyzerSTT: Finalization error: \(error)")
                    #endif
                }
                resultsTaskToFinish?.cancel()

                // Reset state only if no new session has started in the meantime
                guard let self = self, self.sessionID == session else { return }
                self.lastTranscription = ""
                self.accumulatedTranscription = ""
            }
        } else {
            // Reset state
            lastTranscription = ""
            accumulatedTranscription = ""
        }

        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
    }

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioSource == .external, isListening else { return }

        // Update audio level monitor
        if let channelData = buffer.floatChannelData {
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            audioLevelMonitor.updateLevel(from: samples)
        }

        // Handle pre-buffering or direct sending
        preBufferLock.lock()
        let shouldPreBuffer = isPreBuffering
        preBufferLock.unlock()

        if shouldPreBuffer {
            addToPreBuffer(buffer)
        } else {
            bufferContinuation?.yield(buffer)
        }
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [RealtimeSTTModelInfo(
            id: "default",
            name: "Apple Speech",
            description: NSLocalizedString("On-device speech recognition (macOS 26+)", comment: "Apple Speech model description"),
            isDefault: true
        )]
    }

    // MARK: - Private Methods

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

        // Install tap to capture audio - use smaller buffer for lower latency
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isListening else { return }

            // Update audio level monitor
            if let channelData = buffer.floatChannelData {
                let frameLength = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                self.audioLevelMonitor.updateLevel(from: samples)
            }

            // Handle pre-buffering or direct sending
            self.preBufferLock.lock()
            let shouldPreBuffer = self.isPreBuffering
            self.preBufferLock.unlock()

            if shouldPreBuffer {
                self.addToPreBuffer(buffer)
            } else {
                self.bufferContinuation?.yield(buffer)
            }
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()
        configurationObserver = AudioEngineConfigurationObserver(engine: audioEngine) { [weak self] in
            self?.stopAfterAudioConfigurationChange(of: self?.audioEngine)
        }
    }

    private func addToPreBuffer(_ buffer: AVAudioPCMBuffer) {
        // Create a copy of the buffer for storage
        guard let bufferCopy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return
        }
        bufferCopy.frameLength = buffer.frameLength

        if let srcData = buffer.floatChannelData, let dstData = bufferCopy.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dstData[channel], srcData[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
        }

        preBufferLock.lock()
        preBuffer.append(bufferCopy)

        // Limit pre-buffer size based on duration
        let sampleRate = buffer.format.sampleRate
        let maxFrames = Int(maxPreBufferDuration * sampleRate)
        var totalFrames = preBuffer.reduce(0) { $0 + Int($1.frameLength) }

        while totalFrames > maxFrames && preBuffer.count > 1 {
            let removed = preBuffer.removeFirst()
            totalFrames -= Int(removed.frameLength)
        }

        preBufferLock.unlock()

        #if DEBUG
        if preBuffer.count % 20 == 0 {
            debugLog("SpeechAnalyzerSTT: Pre-buffered \(preBuffer.count) buffers")
        }
        #endif
    }

    private func flushPreBuffer() async {
        let buffersToFlush = preBufferLock.withLock {
            let buffers = preBuffer
            preBuffer.removeAll()
            return buffers
        }

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Flushing \(buffersToFlush.count) pre-buffered audio chunks")
        #endif

        // Enqueue through the same serial pipeline so pre-buffered audio stays
        // ahead of live buffers in order
        for buffer in buffersToFlush {
            bufferContinuation?.yield(buffer)
        }

        // Stop pre-buffering only after the drained buffers are enqueued, then
        // pick up any buffers that arrived while flushing
        let stragglers = preBufferLock.withLock {
            isPreBuffering = false
            let buffers = preBuffer
            preBuffer.removeAll()
            return buffers
        }
        for buffer in stragglers {
            bufferContinuation?.yield(buffer)
        }
    }

    // Single consumer of the buffer stream. Runs detached from the main actor so
    // conversion doesn't block the UI; the serial loop preserves buffer order.
    private nonisolated func runBufferPipeline(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        format: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async {
        var audioConverter: AVAudioConverter?
        var bufferCount = 0

        for await buffer in stream {
            bufferCount += 1
            #if DEBUG
            if bufferCount == 1 {
                debugLog("SpeechAnalyzerSTT: First audio buffer sent to analyzer")
            } else if bufferCount % 50 == 0 {
                debugLog("SpeechAnalyzerSTT: Sent \(bufferCount) buffers...")
            }
            #endif

            do {
                // Convert buffer if needed
                let convertedBuffer: AVAudioPCMBuffer
                if let converter = audioConverter {
                    convertedBuffer = try convertBuffer(buffer, using: converter, to: format)
                } else if buffer.format == format {
                    convertedBuffer = buffer
                } else {
                    // Create converter on demand if formats don't match
                    guard let newConverter = AVAudioConverter(from: buffer.format, to: format) else {
                        #if DEBUG
                        debugLog("SpeechAnalyzerSTT: Failed to create audio converter")
                        #endif
                        continue
                    }
                    audioConverter = newConverter
                    convertedBuffer = try convertBuffer(buffer, using: newConverter, to: format)
                }

                // Yield to analyzer
                let input = AnalyzerInput(buffer: convertedBuffer)
                continuation.yield(input)

            } catch {
                #if DEBUG
                debugLog("SpeechAnalyzerSTT: Buffer conversion error: \(error)")
                #endif
            }
        }
    }

    private nonisolated func convertBuffer(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        // Calculate output frame capacity based on sample rate ratio
        let sampleRateRatio = format.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCapacity) else {
            throw RealtimeSTTError.audioError("Failed to create output buffer")
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            throw RealtimeSTTError.audioError("Audio conversion failed: \(error.localizedDescription)")
        }

        return outputBuffer
    }

    private func startResultsMonitoring() {
        guard let transcriber = transcriber else { return }
        let session = sessionID

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    // Stop if cancelled or a newer session has taken over
                    guard let self = self, !Task.isCancelled, self.sessionID == session else { break }

                    // Extract text from AttributedString properly
                    // Note: String(result.text.characters) returns Slice description, not the actual text
                    var currentText = ""
                    for char in result.text.characters {
                        currentText.append(char)
                    }

                    #if DEBUG
                    debugLog("SpeechAnalyzerSTT: Received result - isFinal: \(result.isFinal), text: '\(currentText)'")
                    #endif

                    await MainActor.run { [currentText] in
                        // Build full transcription by combining accumulated + current
                        let fullTranscription: String
                        if self.accumulatedTranscription.isEmpty {
                            fullTranscription = currentText
                        } else if currentText.isEmpty {
                            fullTranscription = self.accumulatedTranscription
                        } else {
                            fullTranscription = self.accumulatedTranscription + " " + currentText
                        }

                        if result.isFinal {
                            // Final result - add to accumulated and notify
                            if !currentText.isEmpty {
                                if self.accumulatedTranscription.isEmpty {
                                    self.accumulatedTranscription = currentText
                                } else {
                                    self.accumulatedTranscription += " " + currentText
                                }
                            }
                            #if DEBUG
                            debugLog("SpeechAnalyzerSTT: Notifying FINAL: '\(fullTranscription)'")
                            #endif
                            self.delegate?.realtimeSTT(self, didReceiveFinalResult: fullTranscription)
                            self.lastTranscription = currentText
                        } else {
                            // Volatile result - show combined text but don't accumulate yet
                            if fullTranscription != self.lastTranscription {
                                #if DEBUG
                                debugLog("SpeechAnalyzerSTT: Notifying PARTIAL: '\(fullTranscription)'")
                                #endif
                                self.delegate?.realtimeSTT(self, didReceivePartialResult: fullTranscription)
                                self.lastTranscription = fullTranscription
                            }
                        }
                    }
                }
            } catch {
                guard let self = self, !Task.isCancelled else { return }

                await MainActor.run {
                    #if DEBUG
                    debugLog("SpeechAnalyzerSTT: Results stream error: \(error)")
                    #endif
                    self.delegate?.realtimeSTT(self, didFailWithError: error)
                }
            }
        }
    }
}

#endif // compiler(>=6.1)
