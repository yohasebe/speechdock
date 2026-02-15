import Foundation
import Speech
@preconcurrency import AVFoundation

// SpeechAnalyzer APIs are only available in macOS 26+ SDK (Xcode 17+)
// Use compile-time check to avoid errors on older SDKs
#if compiler(>=6.1)

// Debug logging helper
private func debugLog(_ message: String) {
    #if DEBUG
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(timestamp)] \(message)")
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
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    // MARK: - Audio Components

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?

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

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - RealtimeSTTService Methods

    func startListening() async throws {
        // Stop any existing session
        stopListening()

        #if DEBUG
        let startTime = Date()
        debugLog("SpeechAnalyzerSTT: Starting setup...")
        #endif

        // Reset pre-buffer state
        preBufferLock.lock()
        preBuffer.removeAll()
        isPreBuffering = true
        preBufferLock.unlock()

        // Start audio capture FIRST to avoid missing initial audio
        if audioSource == .microphone {
            try await startAudioCapture()
        }

        isListening = true
        audioLevelMonitor.start()
        delegate?.realtimeSTT(self, didChangeListeningState: true)

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Audio capture started, now setting up analyzer...")
        #endif

        // Create locale based on selected language
        let locale: Locale
        if !selectedLanguage.isEmpty,
           let langCode = LanguageCode(rawValue: selectedLanguage),
           let localeId = langCode.toLocaleIdentifier() {
            locale = Locale(identifier: localeId)
        } else {
            // Auto mode: construct a BCP-47 locale from system language
            // Locale.current can produce identifiers like "ja_JP" which SpeechTranscriber may not support
            let langId = Locale.current.language.languageCode?.identifier ?? "en"
            let regionId = Locale.current.region?.identifier ?? "US"
            locale = Locale(identifier: "\(langId)-\(regionId)")
        }

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Creating transcriber for locale: \(locale.identifier)...")
        #endif

        // Initialize SpeechTranscriber for live transcription
        // Using reportingOptions: [.volatileResults, .fastResults] for fastest real-time results
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Transcriber created in \(Date().timeIntervalSince(startTime))s")
        #endif

        guard let transcriber = transcriber else {
            throw RealtimeSTTError.serviceUnavailable("Failed to create SpeechTranscriber")
        }

        // Initialize SpeechAnalyzer with the transcriber module
        analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let analyzer = analyzer else {
            throw RealtimeSTTError.serviceUnavailable("Failed to create SpeechAnalyzer")
        }

        // Get the best available audio format for the transcriber
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        guard analyzerFormat != nil else {
            throw RealtimeSTTError.audioError("Failed to get analyzer audio format")
        }

        // Create AsyncStream for audio input
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Start results monitoring task
        startResultsMonitoring()

        // Start the analyzer
        try await analyzer.start(inputSequence: inputSequence)

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Analyzer started, flushing pre-buffer...")
        #endif

        // Flush pre-buffered audio to the analyzer
        await flushPreBuffer()

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Started listening with locale: \(locale.identifier) (total setup: \(Date().timeIntervalSince(startTime))s)")
        #endif
    }

    func stopListening() {
        // Stop audio engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil
        audioLevelMonitor.stop()

        // Clear pre-buffer
        preBufferLock.lock()
        preBuffer.removeAll()
        isPreBuffering = false
        preBufferLock.unlock()

        // Finish the input stream
        inputContinuation?.finish()
        inputContinuation = nil

        // Cancel results monitoring task
        resultsTask?.cancel()
        resultsTask = nil

        // Finalize the analyzer asynchronously (required by API)
        let analyzerToFinalize = analyzer
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil

        if let analyzerToFinalize = analyzerToFinalize {
            Task {
                do {
                    try await analyzerToFinalize.finalizeAndFinishThroughEndOfInput()
                } catch {
                    #if DEBUG
                    debugLog("SpeechAnalyzerSTT: Finalization error: \(error)")
                    #endif
                }
            }
        }

        // Reset state
        lastTranscription = ""
        accumulatedTranscription = ""
        bufferCount = 0
        lastBufferTime = nil

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
            Task {
                await sendBufferToAnalyzer(buffer)
            }
        }
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [RealtimeSTTModelInfo(
            id: "default",
            name: "Apple Speech",
            description: "Advanced on-device speech recognition (macOS 26+)",
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
                Task { [weak self] in
                    await self?.sendBufferToAnalyzer(buffer)
                }
            }
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()
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
        preBufferLock.lock()
        let buffersToFlush = preBuffer
        preBuffer.removeAll()
        isPreBuffering = false
        preBufferLock.unlock()

        #if DEBUG
        debugLog("SpeechAnalyzerSTT: Flushing \(buffersToFlush.count) pre-buffered audio chunks")
        #endif

        for buffer in buffersToFlush {
            await sendBufferToAnalyzer(buffer)
        }
    }

    private var bufferCount = 0
    private var lastBufferTime: Date?

    private func sendBufferToAnalyzer(_ buffer: AVAudioPCMBuffer) async {
        guard let analyzerFormat = analyzerFormat,
              let inputContinuation = inputContinuation else { return }

        bufferCount += 1
        #if DEBUG
        if bufferCount == 1 {
            lastBufferTime = Date()
            debugLog("SpeechAnalyzerSTT: First audio buffer sent to analyzer")
        } else if bufferCount % 50 == 0 {
            debugLog("SpeechAnalyzerSTT: Sent \(bufferCount) buffers...")
        }
        #endif

        do {
            // Convert buffer if needed
            let convertedBuffer: AVAudioPCMBuffer
            if let converter = audioConverter {
                convertedBuffer = try convertBuffer(buffer, using: converter, to: analyzerFormat)
            } else if buffer.format == analyzerFormat {
                convertedBuffer = buffer
            } else {
                // Create converter on demand if formats don't match
                guard let newConverter = AVAudioConverter(from: buffer.format, to: analyzerFormat) else {
                    #if DEBUG
                    debugLog("SpeechAnalyzerSTT: Failed to create audio converter")
                    #endif
                    return
                }
                audioConverter = newConverter
                convertedBuffer = try convertBuffer(buffer, using: newConverter, to: analyzerFormat)
            }

            // Yield to analyzer
            let input = AnalyzerInput(buffer: convertedBuffer)
            inputContinuation.yield(input)

        } catch {
            #if DEBUG
            debugLog("SpeechAnalyzerSTT: Buffer conversion error: \(error)")
            #endif
        }
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
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

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self = self, !Task.isCancelled else { break }

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
