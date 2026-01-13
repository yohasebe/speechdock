import Foundation
@preconcurrency import AVFoundation

/// Google Gemini API for speech-to-text with continuous recording
@MainActor
final class GeminiRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "gemini-2.5-flash"
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects, no language param)
    var audioInputDeviceUID: String = ""  // "" = System Default
    var audioSource: STTAudioSource = .microphone

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var transcriptionTimer: Timer?

    private let apiKeyManager = APIKeyManager.shared
    private let transcriptionInterval: TimeInterval = 2.0
    private let transcriptionTimeout: TimeInterval = 30.0  // Timeout to auto-reset isTranscribing flag

    private var isTranscribing = false
    private var transcriptionStartTime: Date?

    func startListening() async throws {
        guard let _ = apiKeyManager.getAPIKey(for: .gemini) else {
            throw RealtimeSTTError.apiError("Gemini API key not found")
        }

        // Stop any existing session
        stopListening()

        // Create temp file for audio
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt_\(UUID().uuidString).wav")

        if audioSource == .microphone {
            // Start audio capture from microphone
            try await startAudioCapture()
        } else {
            // For external source, create audio file with 16kHz mono format
            guard let tempURL = tempFileURL else {
                throw RealtimeSTTError.audioError("Failed to create temp file")
            }
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            audioFile = try AVAudioFile(forWriting: tempURL, settings: settings)
        }

        // Start periodic transcription
        startTranscriptionTimer()

        isListening = true
        delegate?.realtimeSTT(self, didChangeListeningState: true)
    }

    func stopListening() {
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        audioFile = nil

        // Clean up temp file (no final transcription - periodic already covers it)
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }

        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
    }

    /// Process audio buffer from external source
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard audioSource == .external, isListening, let audioFile = audioFile else { return }
        do {
            try audioFile.write(from: buffer)
        } catch {
            print("Failed to write external audio: \(error)")
        }
    }

    private func startAudioCapture() async throws {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine, let tempURL = tempFileURL else {
            throw RealtimeSTTError.audioError("Failed to create audio engine")
        }

        // Set audio input device if specified
        if !audioInputDeviceUID.isEmpty,
           let device = AudioInputManager.shared.device(withUID: audioInputDeviceUID) {
            try AudioInputManager.shared.setInputDevice(device, for: audioEngine)
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Create audio file with the input format
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: recordingFormat.sampleRate,
            AVNumberOfChannelsKey: recordingFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        audioFile = try AVAudioFile(forWriting: tempURL, settings: settings)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }

            do {
                try audioFile.write(from: buffer)
            } catch {
                print("Failed to write audio: \(error)")
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startTranscriptionTimer() {
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: transcriptionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performPeriodicTranscription()
            }
        }
    }

    private func performPeriodicTranscription() async {
        // Auto-reset isTranscribing if it's been stuck for too long (timeout protection)
        if isTranscribing, let startTime = transcriptionStartTime {
            if Date().timeIntervalSince(startTime) > transcriptionTimeout {
                #if DEBUG
                print("GeminiRealtimeSTT: isTranscribing timeout, auto-resetting flag")
                #endif
                isTranscribing = false
                transcriptionStartTime = nil
            }
        }

        guard isListening, !isTranscribing, let tempURL = tempFileURL else { return }

        // Check if file has content
        guard FileManager.default.fileExists(atPath: tempURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let fileSize = attrs[.size] as? Int,
              fileSize > 1000 else {
            return
        }

        isTranscribing = true
        transcriptionStartTime = Date()
        defer {
            isTranscribing = false
            transcriptionStartTime = nil
        }

        do {
            let transcription = try await transcribeAudio(at: tempURL)
            if !transcription.isEmpty {
                delegate?.realtimeSTT(self, didReceivePartialResult: transcription)
            }
        } catch {
            print("Transcription error: \(error)")
        }
    }

    private func transcribeAudio(at audioFileURL: URL) async throws -> String {
        guard let apiKey = apiKeyManager.getAPIKey(for: .gemini) else {
            throw RealtimeSTTError.apiError("Gemini API key not found")
        }

        // Read audio file and convert to base64
        let audioData = try Data(contentsOf: audioFileURL)
        let base64Audio = audioData.base64EncodedString()

        // Build request to Gemini API
        let model = selectedModel.isEmpty ? "gemini-2.5-flash" : selectedModel
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"

        guard let apiURL = URL(string: endpoint) else {
            throw RealtimeSTTError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

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
                            "text": "Transcribe the audio exactly as spoken. Output ONLY the transcription text with no explanation. For Japanese, do NOT add spaces between words or characters. Write naturally like: 今日はいい天気ですね (NOT: 今日 は いい 天気 です ね)."
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": 2048
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

        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", description: "Fast, multimodal", isDefault: true),
            RealtimeSTTModelInfo(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", description: "Previous generation"),
            RealtimeSTTModelInfo(id: "gemini-1.5-pro", name: "Gemini 1.5 Pro", description: "High quality")
        ]
    }
}
