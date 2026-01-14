import Foundation
@preconcurrency import AVFoundation

/// Google Gemini TTS API implementation
@MainActor
final class GeminiTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool { playbackController.isSpeaking }
    var isPaused: Bool { playbackController.isPaused }

    var selectedVoice: String = "Zephyr"  // Default voice
    var selectedModel: String = "gemini-2.5-flash-preview-tts"
    var selectedSpeed: Double = 1.0  // Speed multiplier (uses prompt-based control)
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects from text)
    var audioOutputDeviceUID: String = "" {
        didSet { playbackController.outputDeviceUID = audioOutputDeviceUID }
    }

    private(set) var lastAudioData: Data?
    var audioFileExtension: String { "m4a" }

    var supportsSpeedControl: Bool { true }

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    override init() {
        super.init()
        setupPlaybackController()
    }

    private func setupPlaybackController() {
        playbackController.onWordHighlight = { [weak self] range, text in
            guard let self = self else { return }
            self.delegate?.tts(self, willSpeakRange: range, of: text)
        }
        playbackController.onFinishSpeaking = { [weak self] success in
            guard let self = self else { return }
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        playbackController.onError = { [weak self] error in
            guard let self = self else { return }
            self.delegate?.tts(self, didFailWithError: error)
        }
    }

    func speak(text: String) async throws {
        guard !text.isEmpty else {
            throw TTSError.noTextProvided
        }

        guard let apiKey = apiKeyManager.getAPIKey(for: .gemini) else {
            throw TTSError.apiError("Gemini API key not found")
        }

        stop()

        // Prepare text for highlighting
        playbackController.prepareText(text)

        // Build API request
        let modelId = selectedModel.isEmpty ? "gemini-2.5-flash-preview-tts" : selectedModel
        let urlString = "\(baseURL)/\(modelId):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw TTSError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // Validate voice - use default if invalid, and convert to lowercase
        let validVoice = Self.validVoiceIds.contains(selectedVoice.lowercased()) ? selectedVoice.lowercased() : "zephyr"

        // Prepend pace instruction to text (like monadic-chat does)
        let paceInstruction = paceInstructionForSpeed(selectedSpeed)
        let textWithPace = paceInstruction + text

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": textWithPace]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": validVoice
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Perform request with retry logic for transient errors
        let (data, _) = try await TTSAPIHelper.performRequest(request, providerName: "Gemini")

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw TTSError.apiError("Invalid response format")
        }

        // Collect all audio parts (Gemini may return multiple parts for longer audio)
        var combinedAudioData = Data()
        var detectedMimeType = ""

        for part in parts {
            guard let inlineData = part["inlineData"] as? [String: Any],
                  let base64Audio = inlineData["data"] as? String,
                  let partData = Data(base64Encoded: base64Audio) else {
                continue
            }

            if detectedMimeType.isEmpty, let mimeType = inlineData["mimeType"] as? String {
                detectedMimeType = mimeType
            }

            combinedAudioData.append(partData)
        }

        guard !combinedAudioData.isEmpty else {
            throw TTSError.audioError("No audio data in response")
        }

        let mimeType = detectedMimeType.isEmpty ? "audio/L16;rate=24000" : detectedMimeType
        let audioData = combinedAudioData

        // Handle PCM audio (L16) by adding WAV header
        let finalAudioData: Data
        let sourceExt: String
        if mimeType.contains("L16") || mimeType.contains("pcm") {
            finalAudioData = createWAVFromPCM(audioData, mimeType: mimeType)
            sourceExt = "wav"
        } else {
            finalAudioData = audioData
            sourceExt = "wav"  // Gemini typically returns WAV-compatible format
        }

        // Convert to M4A (AAC) in background for smaller file size
        Task {
            if let m4aData = await AudioConverter.convertToAAC(inputData: finalAudioData, inputExtension: sourceExt) {
                await MainActor.run {
                    self.lastAudioData = m4aData
                }
            } else {
                // Fallback to original format if conversion fails
                await MainActor.run {
                    self.lastAudioData = finalAudioData
                }
            }
        }

        // Play the audio
        try playbackController.playAudio(data: finalAudioData, fileExtension: sourceExt)
    }

    func pause() {
        playbackController.pause()
    }

    func resume() {
        playbackController.resume()
    }

    func stop() {
        playbackController.stopPlayback()
    }

    func clearAudioCache() {
        lastAudioData = nil
    }

    // MARK: - Gemini-specific Helpers

    private func createWAVFromPCM(_ pcmData: Data, mimeType: String) -> Data {
        // Extract sample rate from MIME type (e.g., "audio/L16;rate=24000")
        var sampleRate: UInt32 = 24000
        if let rateMatch = mimeType.range(of: "rate=") {
            let rateStart = mimeType.index(rateMatch.upperBound, offsetBy: 0)
            var rateEnd = rateStart
            while rateEnd < mimeType.endIndex && mimeType[rateEnd].isNumber {
                rateEnd = mimeType.index(after: rateEnd)
            }
            if let rate = UInt32(mimeType[rateStart..<rateEnd]) {
                sampleRate = rate
            }
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        var wavData = Data()

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // AudioFormat (PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data subchunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        wavData.append(pcmData)

        return wavData
    }

    /// Generate pace instruction for Gemini TTS based on speed setting
    /// Based on monadic-chat's implementation - always include a pace instruction
    private func paceInstructionForSpeed(_ speed: Double) -> String {
        // Map speed multiplier to natural language pace instruction
        // Always include instruction (even for normal speed) - this is key for Gemini TTS
        switch speed {
        case ..<0.6:
            return "Speak very slowly and deliberately. "
        case 0.6..<0.8:
            return "Speak slowly and take your time. "
        case 0.8..<0.95:
            return "Speak at a slightly slower pace than normal. "
        case 0.95..<1.15:
            // Normal speed - still include instruction
            return "Speak at a natural, conversational pace. "
        case 1.15..<1.4:
            return "Speak at a slightly faster pace than normal. "
        case 1.4..<1.8:
            return "Speak quickly and at a faster pace. "
        case 1.8...:
            return "[extremely fast] "
        default:
            return "Speak at a natural, conversational pace. "
        }
    }

    /// Valid Gemini voice IDs (lowercase)
    private static let validVoiceIds: Set<String> = [
        "zephyr", "puck", "charon", "kore", "fenrir", "aoede", "orus",
        "leda", "callirrhoe", "autonoe", "enceladus", "iapetus", "umbriel",
        "algieba", "despina", "erinome", "algenib", "rasalgethi", "laomedeia",
        "achernar", "alnilam", "schedar", "gacrux", "pulcherrima", "achird",
        "zubenelgenubi", "vindemiatrix", "sadachbia", "sadaltager", "sulafat"
    ]

    func availableVoices() -> [TTSVoice] {
        // Gemini TTS available voices (30 voices from monadic-chat)
        [
            TTSVoice(id: "zephyr", name: "Zephyr", language: "multi", isDefault: true),
            TTSVoice(id: "puck", name: "Puck", language: "multi"),
            TTSVoice(id: "charon", name: "Charon", language: "multi"),
            TTSVoice(id: "kore", name: "Kore", language: "multi"),
            TTSVoice(id: "fenrir", name: "Fenrir", language: "multi"),
            TTSVoice(id: "aoede", name: "Aoede", language: "multi"),
            TTSVoice(id: "orus", name: "Orus", language: "multi"),
            TTSVoice(id: "leda", name: "Leda", language: "multi"),
            TTSVoice(id: "callirrhoe", name: "Callirrhoe", language: "multi"),
            TTSVoice(id: "autonoe", name: "Autonoe", language: "multi"),
            TTSVoice(id: "enceladus", name: "Enceladus", language: "multi"),
            TTSVoice(id: "iapetus", name: "Iapetus", language: "multi"),
            TTSVoice(id: "umbriel", name: "Umbriel", language: "multi"),
            TTSVoice(id: "algieba", name: "Algieba", language: "multi"),
            TTSVoice(id: "despina", name: "Despina", language: "multi"),
            TTSVoice(id: "erinome", name: "Erinome", language: "multi"),
            TTSVoice(id: "algenib", name: "Algenib", language: "multi"),
            TTSVoice(id: "rasalgethi", name: "Rasalgethi", language: "multi"),
            TTSVoice(id: "laomedeia", name: "Laomedeia", language: "multi"),
            TTSVoice(id: "achernar", name: "Achernar", language: "multi"),
            TTSVoice(id: "alnilam", name: "Alnilam", language: "multi"),
            TTSVoice(id: "schedar", name: "Schedar", language: "multi"),
            TTSVoice(id: "gacrux", name: "Gacrux", language: "multi"),
            TTSVoice(id: "pulcherrima", name: "Pulcherrima", language: "multi"),
            TTSVoice(id: "achird", name: "Achird", language: "multi"),
            TTSVoice(id: "zubenelgenubi", name: "Zubenelgenubi", language: "multi"),
            TTSVoice(id: "vindemiatrix", name: "Vindemiatrix", language: "multi"),
            TTSVoice(id: "sadachbia", name: "Sadachbia", language: "multi"),
            TTSVoice(id: "sadaltager", name: "Sadaltager", language: "multi"),
            TTSVoice(id: "sulafat", name: "Sulafat", language: "multi")
        ]
    }

    func availableModels() -> [TTSModelInfo] {
        [
            TTSModelInfo(id: "gemini-2.5-flash-preview-tts", name: "Gemini 2.5 Flash TTS", description: "Fast, multilingual", isDefault: true),
            TTSModelInfo(id: "gemini-2.5-pro-preview-tts", name: "Gemini 2.5 Pro TTS", description: "Higher quality")
        ]
    }

    func speedRange() -> ClosedRange<Double> {
        // Gemini uses prompt-based pace control
        // We map speed values to pace instructions
        0.5...2.0
    }
}
