import Foundation
@preconcurrency import AVFoundation

/// OpenAI Whisper API for speech-to-text (record then transcribe)
@MainActor
final class OpenAIRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "gpt-4o-transcribe"
    var selectedLanguage: String = ""  // "" = Auto (OpenAI auto-detects)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    private var audioEngine: AVAudioEngine?

    // Audio buffer (no max limit - record until stop)
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()

    // VAD for auto-stop
    private let vadService = VADService.shared
    private var vadBuffer: [Float] = []
    private let vadChunkSize = 4096  // 256ms at 16kHz
    private var silenceStartTime: Date?
    private var recordingStartTime: Date?

    // VAD auto-stop settings (configurable via AppState)
    var vadMinimumRecordingTime: TimeInterval = 10.0
    var vadSilenceDuration: TimeInterval = 3.0

    // Audio level monitoring
    private let audioLevelMonitor = AudioLevelMonitor.shared

    private let apiKeyManager = APIKeyManager.shared
    private let sampleRate: Double = 16000

    func startListening() async throws {
        guard apiKeyManager.getAPIKey(for: .openAI) != nil else {
            throw RealtimeSTTError.apiError("OpenAI API key not found")
        }

        // Stop any existing session
        stopListening()

        // Reset state
        bufferLock.lock()
        audioBuffer.removeAll()
        vadBuffer.removeAll()
        bufferLock.unlock()
        silenceStartTime = nil
        recordingStartTime = Date()
        vadService.reset()
        audioLevelMonitor.start()

        // Start audio capture FIRST for immediate response
        if audioSource == .microphone {
            try await startAudioCapture()
        }

        isListening = true
        delegate?.realtimeSTT(self, didChangeListeningState: true)

        // Initialize VAD in background (non-blocking)
        Task {
            do {
                try await vadService.initialize()
            } catch {
                #if DEBUG
                print("OpenAIRealtimeSTT: VAD initialization failed: \(error)")
                #endif
            }
        }
    }

    func stopListening() {
        let wasListening = isListening
        isListening = false

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioLevelMonitor.stop()

        if wasListening {
            // Transcribe the recorded audio
            Task {
                await transcribeRecordedAudio()
            }
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
    }

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioSource == .external, isListening else { return }
        appendToBuffer(buffer)
    }

    private func appendToBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        vadBuffer.append(contentsOf: samples)
        bufferLock.unlock()

        // Update audio level monitor
        audioLevelMonitor.updateLevel(from: samples)

        // Process VAD for auto-stop
        Task {
            await processVADForAutoStop()
        }
    }

    private func processVADForAutoStop() async {
        guard vadService.isReady, isListening else { return }

        // Check if minimum recording time has passed
        guard let startTime = recordingStartTime,
              Date().timeIntervalSince(startTime) >= vadMinimumRecordingTime else {
            return
        }

        bufferLock.lock()
        while vadBuffer.count >= vadChunkSize {
            let chunk = Array(vadBuffer.prefix(vadChunkSize))
            vadBuffer.removeFirst(vadChunkSize)
            bufferLock.unlock()

            let result = await vadService.processSamples(chunk)

            if result.isSpeech {
                // Speech detected - reset silence timer
                silenceStartTime = nil
            } else {
                // Silence detected
                if silenceStartTime == nil {
                    silenceStartTime = Date()
                } else if let silenceStart = silenceStartTime,
                          Date().timeIntervalSince(silenceStart) >= vadSilenceDuration {
                    // Silence duration reached - auto-stop
                    #if DEBUG
                    print("OpenAIRealtimeSTT: Auto-stop triggered after \(vadSilenceDuration)s of silence")
                    #endif
                    stopListening()
                    return
                }
            }

            bufferLock.lock()
        }
        bufferLock.unlock()
    }

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

        // Convert to 16kHz mono
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter?.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                self.appendToBuffer(convertedBuffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func transcribeRecordedAudio() async {
        bufferLock.lock()
        let samples = audioBuffer
        audioBuffer.removeAll()
        vadBuffer.removeAll()
        bufferLock.unlock()

        // Need at least 0.5 seconds of audio
        guard samples.count > 8000 else {
            #if DEBUG
            print("OpenAIRealtimeSTT: Recording too short, skipping transcription")
            #endif
            return
        }

        do {
            let transcription = try await transcribeAudio(samples: samples)
            if !transcription.isEmpty {
                delegate?.realtimeSTT(self, didReceiveFinalResult: transcription)
            }
        } catch {
            delegate?.realtimeSTT(self, didFailWithError: error)
        }
    }

    private func transcribeAudio(samples: [Float]) async throws -> String {
        guard let apiKey = apiKeyManager.getAPIKey(for: .openAI) else {
            throw RealtimeSTTError.apiError("OpenAI API key not found")
        }

        // Convert Float samples to WAV data
        let wavData = createWAVData(from: samples, sampleRate: Int(sampleRate))

        let boundary = UUID().uuidString
        guard let apiURL = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw RealtimeSTTError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60  // Longer timeout for longer recordings

        // Build multipart form data
        var body = Data()

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model
        let model = selectedModel.isEmpty ? "gpt-4o-transcribe" : selectedModel
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Add language if specified
        if !selectedLanguage.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(selectedLanguage)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RealtimeSTTError.apiError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RealtimeSTTError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw RealtimeSTTError.apiError("Invalid response format")
        }

        return text
    }

    /// Create WAV file data from Float samples
    private func createWAVData(from samples: [Float], sampleRate: Int) -> Data {
        var data = Data()

        // Convert float samples to 16-bit PCM
        var pcmData = Data()
        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clipped * 32767.0)
            pcmData.append(contentsOf: withUnsafeBytes(of: intSample.littleEndian) { Array($0) })
        }

        // WAV header
        let dataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + pcmData.count)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * Int(channels) * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(channels * bitsPerSample / 8)

        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        data.append(pcmData)

        return data
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: "gpt-4o-transcribe", name: "GPT-4o Transcribe", description: "GPT-4o based transcription", isDefault: true),
            RealtimeSTTModelInfo(id: "gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe", description: "Faster, lower cost"),
            RealtimeSTTModelInfo(id: "whisper-1", name: "Whisper", description: "OpenAI Whisper large-v2")
        ]
    }
}
