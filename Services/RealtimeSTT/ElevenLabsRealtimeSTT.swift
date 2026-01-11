import Foundation
@preconcurrency import AVFoundation

/// ElevenLabs Scribe API for speech-to-text with continuous recording
@MainActor
final class ElevenLabsRealtimeSTT: NSObject, RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    private(set) var isListening = false
    var selectedModel: String = "scribe_v1"

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var transcriptionTimer: Timer?

    private let apiKeyManager = APIKeyManager.shared
    private let transcriptionInterval: TimeInterval = 2.0

    private var isTranscribing = false

    func startListening() async throws {
        guard let _ = apiKeyManager.getAPIKey(for: .elevenLabs) else {
            throw RealtimeSTTError.apiError("ElevenLabs API key not found")
        }

        // Stop any existing session
        stopListening()

        // Create temp file for audio
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt_\(UUID().uuidString).mp3")

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

        // Create audio file for recording (WAV format)
        let wavURL = tempURL.deletingPathExtension().appendingPathExtension("wav")
        tempFileURL = wavURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: recordingFormat.sampleRate,
            AVNumberOfChannelsKey: recordingFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        audioFile = try AVAudioFile(forWriting: wavURL, settings: settings)

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
        guard let apiKey = apiKeyManager.getAPIKey(for: .elevenLabs) else {
            throw RealtimeSTTError.apiError("ElevenLabs API key not found")
        }

        // Read audio file
        let audioData = try Data(contentsOf: url)

        // Build multipart request to ElevenLabs Speech-to-Text API
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()

        // Add audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add model_id (required)
        let model = selectedModel.isEmpty ? "scribe_v1" : selectedModel
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RealtimeSTTError.apiError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("ElevenLabs STT error: \(errorMessage)")
            throw RealtimeSTTError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("ElevenLabs STT response: \(json)")
            }
            throw RealtimeSTTError.apiError("Invalid response format")
        }

        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    func availableModels() -> [RealtimeSTTModelInfo] {
        [
            RealtimeSTTModelInfo(id: "scribe_v1", name: "Scribe v1", description: "Standard transcription", isDefault: true),
            RealtimeSTTModelInfo(id: "scribe_v1_experimental", name: "Scribe v1 Experimental", description: "Experimental features")
        ]
    }
}
