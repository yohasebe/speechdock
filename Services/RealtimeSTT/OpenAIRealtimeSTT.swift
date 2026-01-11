import Foundation
@preconcurrency import AVFoundation

/// OpenAI Whisper API for speech-to-text with continuous recording
@MainActor
final class OpenAIRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "whisper-1"
    var selectedLanguage: String = ""  // "" = Auto (OpenAI auto-detects)

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var transcriptionTimer: Timer?
    private var lastTranscriptionTime: Date?

    private let apiKeyManager = APIKeyManager.shared
    private let transcriptionInterval: TimeInterval = 2.0

    private var accumulatedTranscription = ""
    private var isTranscribing = false

    func startListening() async throws {
        guard let _ = apiKeyManager.getAPIKey(for: .openAI) else {
            throw RealtimeSTTError.apiError("OpenAI API key not found")
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

        // Create audio file with the input format (no conversion needed for WAV)
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
        lastTranscriptionTime = Date()
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: transcriptionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performPeriodicTranscription()
            }
        }
    }

    private func performPeriodicTranscription() async {
        guard isListening, !isTranscribing, let tempURL = tempFileURL else { return }

        // Check if file has content
        guard FileManager.default.fileExists(atPath: tempURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let fileSize = attrs[.size] as? Int,
              fileSize > 1000 else {  // Minimum file size
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
            // Cleanup
            try? FileManager.default.removeItem(at: tempURL)
            tempFileURL = nil
        }

        // Check if file has content
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
        guard let apiKey = apiKeyManager.getAPIKey(for: .openAI) else {
            throw RealtimeSTTError.apiError("OpenAI API key not found")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Build multipart form data
        var body = Data()

        // Add file
        let audioData = try Data(contentsOf: url)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model
        let model = selectedModel.isEmpty ? "whisper-1" : selectedModel
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Add language if specified (ISO 639-1 format)
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

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: "whisper-1", name: "Whisper", description: "OpenAI Whisper large-v2", isDefault: true),
            RealtimeSTTModelInfo(id: "gpt-4o-transcribe", name: "GPT-4o Transcribe", description: "GPT-4o based transcription"),
            RealtimeSTTModelInfo(id: "gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe", description: "Faster, lower cost")
        ]
    }
}
