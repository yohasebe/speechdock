import Foundation
@preconcurrency import AVFoundation

/// Google Gemini API for speech-to-text with continuous recording
@MainActor
final class GeminiRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "gemini-2.0-flash"
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects, no language param)

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var transcriptionTimer: Timer?

    private let apiKeyManager = APIKeyManager.shared
    private let transcriptionInterval: TimeInterval = 2.0

    private var isTranscribing = false

    func startListening() async throws {
        guard let _ = apiKeyManager.getAPIKey(for: .gemini) else {
            throw RealtimeSTTError.apiError("Gemini API key not found")
        }

        // Stop any existing session
        stopListening()

        // Create temp file for audio
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt_\(UUID().uuidString).wav")

        // Start audio capture
        try await startAudioCapture()

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

        // Final transcription
        if let url = tempFileURL, FileManager.default.fileExists(atPath: url.path) {
            Task {
                await performFinalTranscription()
            }
        }

        if isListening {
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
    }

    private func startAudioCapture() async throws {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine, let tempURL = tempFileURL else {
            throw RealtimeSTTError.audioError("Failed to create audio engine")
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
        guard isListening, !isTranscribing, let tempURL = tempFileURL else { return }

        guard FileManager.default.fileExists(atPath: tempURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let fileSize = attrs[.size] as? Int,
              fileSize > 1000 else {
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let transcription = try await transcribeAudio(at: tempURL)
            if !transcription.isEmpty {
                delegate?.realtimeSTT(self, didReceivePartialResult: transcription)
            }
        } catch {
            print("Transcription error: \(error)")
        }
    }

    private func performFinalTranscription() async {
        guard let tempURL = tempFileURL else { return }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
            tempFileURL = nil
        }

        guard FileManager.default.fileExists(atPath: tempURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let fileSize = attrs[.size] as? Int,
              fileSize > 1000 else {
            return
        }

        do {
            let transcription = try await transcribeAudio(at: tempURL)
            if !transcription.isEmpty {
                delegate?.realtimeSTT(self, didReceiveFinalResult: transcription)
            }
        } catch {
            delegate?.realtimeSTT(self, didFailWithError: error)
        }
    }

    private func transcribeAudio(at url: URL) async throws -> String {
        guard let apiKey = apiKeyManager.getAPIKey(for: .gemini) else {
            throw RealtimeSTTError.apiError("Gemini API key not found")
        }

        // Read audio file and convert to base64
        let audioData = try Data(contentsOf: url)
        let base64Audio = audioData.base64EncodedString()

        // Build request to Gemini API
        let model = selectedModel.isEmpty ? "gemini-2.0-flash" : selectedModel
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"

        var request = URLRequest(url: URL(string: endpoint)!)
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
                            "text": "Transcribe the audio exactly as spoken. Output only the transcription text, nothing else. If the audio is in Japanese, transcribe in Japanese. If in English, transcribe in English."
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
            RealtimeSTTModelInfo(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", description: "Fast, multimodal", isDefault: true),
            RealtimeSTTModelInfo(id: "gemini-1.5-flash", name: "Gemini 1.5 Flash", description: "Balanced speed/quality"),
            RealtimeSTTModelInfo(id: "gemini-1.5-pro", name: "Gemini 1.5 Pro", description: "High quality")
        ]
    }
}
