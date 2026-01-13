import Foundation
@preconcurrency import AVFoundation

/// Google Gemini API for speech-to-text (record then transcribe)
@MainActor
final class GeminiRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "gemini-2.5-flash"
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects)
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
        guard apiKeyManager.getAPIKey(for: .gemini) != nil else {
            throw RealtimeSTTError.apiError("Gemini API key not found")
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
                print("GeminiRealtimeSTT: VAD initialization failed: \(error)")
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
                    print("GeminiRealtimeSTT: Auto-stop triggered after \(vadSilenceDuration)s of silence")
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
            print("GeminiRealtimeSTT: Recording too short, skipping transcription")
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
        guard let apiKey = apiKeyManager.getAPIKey(for: .gemini) else {
            throw RealtimeSTTError.apiError("Gemini API key not found")
        }

        // Convert Float samples to WAV data
        let wavData = createWAVData(from: samples, sampleRate: Int(sampleRate))
        let base64Audio = wavData.base64EncodedString()

        // Build request to Gemini API
        let model = selectedModel.isEmpty ? "gemini-2.5-flash" : selectedModel
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"

        guard let apiURL = URL(string: endpoint) else {
            throw RealtimeSTTError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60  // Longer timeout for longer recordings

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": base64Audio
                            ]
                        ],
                        [
                            "text": "Transcribe audio to text. Output ONLY spoken words. No timestamps, labels, explanations, or formatting. For Japanese/Chinese/Korean: NO spaces between words or characters. Empty string if silent/unclear."
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": 8192
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RealtimeSTTError.apiError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RealtimeSTTError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw RealtimeSTTError.apiError("Invalid response format")
        }

        return cleanTranscription(text)
    }

    private func cleanTranscription(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove common LLM response prefixes
        let prefixesToRemove = [
            "Here is the transcription:",
            "Here's the transcription:",
            "Transcription:",
            "The transcription is:",
            "The audio says:",
        ]
        for prefix in prefixesToRemove {
            if result.lowercased().hasPrefix(prefix.lowercased()) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Remove spurious spaces in Japanese/Chinese/Korean text
        // Check if text is predominantly CJK
        let cjkCount = result.unicodeScalars.filter { scalar in
            (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||  // CJK Unified Ideographs
            (scalar.value >= 0x3040 && scalar.value <= 0x309F) ||  // Hiragana
            (scalar.value >= 0x30A0 && scalar.value <= 0x30FF) ||  // Katakana
            (scalar.value >= 0xAC00 && scalar.value <= 0xD7AF)     // Korean Hangul
        }.count

        if cjkCount > result.count / 3 {  // If more than 1/3 is CJK, remove spaces
            result = result.replacingOccurrences(of: " ", with: "")
        }

        return result
    }

    private func createWAVData(from samples: [Float], sampleRate: Int) -> Data {
        var data = Data()

        var pcmData = Data()
        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clipped * 32767.0)
            pcmData.append(contentsOf: withUnsafeBytes(of: intSample.littleEndian) { Array($0) })
        }

        let dataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + pcmData.count)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * Int(channels) * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(channels * bitsPerSample / 8)

        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        data.append(pcmData)

        return data
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", description: "Fast, multimodal", isDefault: true),
            RealtimeSTTModelInfo(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", description: "Previous generation"),
            RealtimeSTTModelInfo(id: "gemini-1.5-pro", name: "Gemini 1.5 Pro", description: "High quality")
        ]
    }
}
