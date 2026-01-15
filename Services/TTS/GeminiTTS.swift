import Foundation
@preconcurrency import AVFoundation
import NaturalLanguage

/// Google Gemini TTS API implementation with WebSocket streaming support
@MainActor
final class GeminiTTS: NSObject, TTSService {
    weak var delegate: TTSDelegate?

    var isSpeaking: Bool {
        useStreamingMode ? streamingPlayer.isSpeaking : playbackController.isSpeaking
    }
    var isPaused: Bool {
        useStreamingMode ? streamingPlayer.isPaused : playbackController.isPaused
    }

    var selectedVoice: String = "Zephyr"  // Default voice
    var selectedModel: String = "gemini-2.5-flash-preview-tts"
    var selectedSpeed: Double = 1.0  // Speed multiplier (uses prompt-based control)
    var selectedLanguage: String = ""  // "" = Auto (Gemini auto-detects from text)
    var audioOutputDeviceUID: String = "" {
        didSet {
            playbackController.outputDeviceUID = audioOutputDeviceUID
            streamingPlayer.outputDeviceUID = audioOutputDeviceUID
        }
    }

    /// Enable streaming mode for lower latency (default: true)
    var useStreamingMode: Bool = true

    private(set) var lastAudioData: Data?

    /// Track the actual file extension of lastAudioData (m4a or wav fallback)
    private var _audioFileExtension: String = "m4a"
    var audioFileExtension: String { _audioFileExtension }

    var supportsSpeedControl: Bool { true }

    private let apiKeyManager = APIKeyManager.shared
    private let playbackController = TTSAudioPlaybackController()
    private let streamingPlayer = StreamingAudioPlayer()
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    /// WebSocket endpoint for Live API (v1alpha for BidiGenerateContent)
    private let wsBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"

    /// WebSocket task for streaming
    private var webSocketTask: URLSessionWebSocketTask?

    /// Accumulated PCM data for saving (streaming mode)
    private var accumulatedPCMData = Data()

    /// Flag to track if streaming is active
    private var isStreamingActive = false

    override init() {
        super.init()
        setupPlaybackController()
        setupStreamingPlayer()
    }

    private func setupPlaybackController() {
        playbackController.onPlaybackStarted = { [weak self] in
            guard let self = self else { return }
            self.delegate?.ttsDidStartSpeaking(self)
        }
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

    private func setupStreamingPlayer() {
        streamingPlayer.onPlaybackStarted = { [weak self] in
            guard let self = self else { return }
            #if DEBUG
            print("Gemini TTS: Streaming playback started")
            #endif
            self.delegate?.ttsDidStartSpeaking(self)
        }
        streamingPlayer.onPlaybackFinished = { [weak self] success in
            guard let self = self else { return }
            // Note: M4A conversion is handled in speakStreaming() after stream completes
            // Don't store raw PCM here - lastAudioData will be set by the conversion Task
            self.delegate?.tts(self, didFinishSpeaking: success)
        }
        streamingPlayer.onError = { [weak self] error in
            guard let self = self else { return }
            self.delegate?.tts(self, didFailWithError: error)
        }
    }

    /// Character threshold per chunk for streaming mode
    /// Smaller chunks help avoid premature turnComplete issue (known Gemini Live API bug)
    /// Note: Non-ASCII text (Japanese, etc.) produces longer audio per character than English
    private let streamingChunkLimit = 200

    func speak(text: String) async throws {
        guard !text.isEmpty else {
            throw TTSError.noTextProvided
        }

        guard let apiKey = apiKeyManager.getAPIKey(for: .gemini) else {
            throw TTSError.apiError("Gemini API key not found")
        }

        stop()

        if useStreamingMode {
            try await speakStreaming(text: text, apiKey: apiKey)
        } else {
            try await speakNonStreaming(text: text, apiKey: apiKey)
        }
    }

    /// WebSocket streaming playback with chunked text support
    /// Splits long text into chunks to work around Live API's ~60 second limit
    private func speakStreaming(text: String, apiKey: String) async throws {
        accumulatedPCMData = Data()
        isStreamingActive = true

        // Validate voice
        let validVoice = Self.validVoiceIds.contains(selectedVoice.lowercased()) ? selectedVoice.lowercased() : "zephyr"

        // Split text into chunks if needed
        let textChunks = splitTextIntoChunks(text, maxLength: streamingChunkLimit)

        // Create WebSocket URL with API key
        let urlString = "\(wsBaseURL)?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw TTSError.apiError("Invalid WebSocket URL")
        }

        // Create WebSocket task
        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        webSocketTask = wsTask
        wsTask.resume()

        #if DEBUG
        print("Gemini TTS: WebSocket connection started")
        #endif

        // Send setup message
        // Use gemini-2.5-flash-native-audio for Live API with audio output
        let setupMessage: [String: Any] = [
            "setup": [
                "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": validVoice
                            ]
                        ]
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": "You are a text-to-speech engine. Your ONLY function is to vocalize text exactly as written. RULES: 1) Read EVERY word, character, and punctuation mark exactly as provided. 2) NEVER skip, summarize, paraphrase, or omit any part. 3) NEVER add commentary or responses. 4) Read in the same language as the input text. 5) Read numbered lists, citations, and special characters verbatim."]
                    ]
                ]
            ]
        ]

        let setupData = try JSONSerialization.data(withJSONObject: setupMessage)
        let setupString = String(data: setupData, encoding: .utf8)!
        try await wsTask.send(.string(setupString))

        // Wait for setupComplete response
        let setupResponse = try await wsTask.receive()
        switch setupResponse {
        case .string(let responseText):
            guard responseText.contains("setupComplete") else {
                throw TTSError.apiError("Setup failed: \(responseText)")
            }
        case .data(let data):
            if let responseText = String(data: data, encoding: .utf8) {
                guard responseText.contains("setupComplete") else {
                    throw TTSError.apiError("Setup failed: \(responseText)")
                }
            } else {
                throw TTSError.apiError("Unexpected binary response during setup")
            }
        @unknown default:
            throw TTSError.apiError("Unknown response type during setup")
        }

        #if DEBUG
        print("Gemini TTS: Setup complete")
        #endif

        // Start streaming player
        try streamingPlayer.startStreaming()

        var totalChunkCount = 0
        var totalAudioBytes = 0

        // Process each text chunk
        for (chunkIndex, chunk) in textChunks.enumerated() {
            guard isStreamingActive else { break }

            #if DEBUG
            print("Gemini TTS: Sending chunk \(chunkIndex + 1)/\(textChunks.count) (\(chunk.count) chars)")
            #endif

            // Send text chunk with explicit verbatim instruction
            let textToSpeak = "READ VERBATIM (do not skip or summarize):\n\n\(chunk)"

            let clientContent: [String: Any] = [
                "clientContent": [
                    "turns": [
                        [
                            "role": "user",
                            "parts": [
                                ["text": textToSpeak]
                            ]
                        ]
                    ],
                    "turnComplete": true
                ]
            ]

            let contentData = try JSONSerialization.data(withJSONObject: clientContent)
            let contentString = String(data: contentData, encoding: .utf8)!
            try await wsTask.send(.string(contentString))

            // Receive audio for this chunk
            var receivedTurnComplete = false
            var chunkAudioBytes = 0
            var chunkAudioPackets = 0

            while isStreamingActive && !receivedTurnComplete {
                do {
                    let message = try await wsTask.receive()

                    let jsonData: Data?
                    switch message {
                    case .string(let text):
                        jsonData = text.data(using: .utf8)
                    case .data(let data):
                        jsonData = data
                    @unknown default:
                        continue
                    }

                    guard let data = jsonData,
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }

                    if let serverContent = json["serverContent"] as? [String: Any] {
                        // Process audio data first (before checking turnComplete)
                        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                           let parts = modelTurn["parts"] as? [[String: Any]] {
                            for part in parts {
                                if let inlineData = part["inlineData"] as? [String: Any],
                                   let base64Audio = inlineData["data"] as? String,
                                   var audioData = Data(base64Encoded: base64Audio) {
                                    // Check mime type - L16 is big-endian, need to convert to little-endian
                                    if let mimeType = inlineData["mimeType"] as? String,
                                       mimeType.contains("L16") {
                                        audioData = convertBigEndianToLittleEndian(audioData)
                                    }
                                    streamingPlayer.appendData(audioData)
                                    accumulatedPCMData.append(audioData)
                                    totalChunkCount += 1
                                    totalAudioBytes += audioData.count
                                    chunkAudioBytes += audioData.count
                                    chunkAudioPackets += 1
                                }
                            }
                        }

                        // Check turnComplete after processing audio
                        if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                            receivedTurnComplete = true
                        }
                    }
                } catch {
                    if isStreamingActive {
                        #if DEBUG
                        print("Gemini TTS: WebSocket receive error: \(error.localizedDescription)")
                        #endif
                        // Mark streaming as inactive to stop processing
                        isStreamingActive = false
                        // Close WebSocket immediately on error
                        wsTask.cancel(with: .abnormalClosure, reason: nil)
                        webSocketTask = nil
                    }
                    break
                }
            }

            #if DEBUG
            if chunkAudioBytes == 0 {
                print("Gemini TTS: WARNING - No audio received for chunk \(chunkIndex + 1)!")
            }
            #endif

            // Exit for loop if streaming was stopped due to error
            if !isStreamingActive {
                break
            }
        }

        // Signal end of stream
        streamingPlayer.finishStream()

        // Close WebSocket if still open
        if webSocketTask != nil {
            wsTask.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
        }
        isStreamingActive = false

        #if DEBUG
        print("Gemini TTS: All chunks complete. Total: \(totalChunkCount) audio chunks, \(totalAudioBytes) bytes")
        #endif

        // Convert accumulated PCM to M4A for saving (await to ensure lastAudioData is ready for Save Audio)
        if !accumulatedPCMData.isEmpty {
            // First convert PCM to WAV (add header)
            let wavData = AudioConverter.createWAVFromPCM(accumulatedPCMData)

            // Clear accumulated PCM data to free memory before conversion
            accumulatedPCMData = Data()

            // Then convert WAV to M4A (await completion to avoid race condition with Save Audio)
            if let m4aData = await AudioConverter.convertToAAC(inputData: wavData, inputExtension: "wav") {
                lastAudioData = m4aData
                _audioFileExtension = "m4a"
                #if DEBUG
                print("Gemini TTS: Converted to M4A, size: \(m4aData.count) bytes")
                #endif
            } else {
                // Fallback to WAV if M4A conversion fails
                lastAudioData = wavData
                _audioFileExtension = "wav"
                #if DEBUG
                print("Gemini TTS: M4A conversion failed, using WAV")
                #endif
            }
        }
    }

    /// Split text into chunks at sentence boundaries using NLTokenizer
    /// Ensures we never split in the middle of a sentence
    private func splitTextIntoChunks(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else {
            return [text]
        }

        // First, get all sentences using NLTokenizer
        let sentences = tokenizeIntoSentences(text)

        // Group sentences into chunks that don't exceed maxLength
        var chunks: [String] = []
        var currentChunk = ""

        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmedSentence.isEmpty else { continue }

            // Check if adding this sentence would exceed the limit
            let separator = currentChunk.isEmpty ? "" : " "
            let potentialLength = currentChunk.count + separator.count + trimmedSentence.count

            if potentialLength > maxLength && !currentChunk.isEmpty {
                // Save current chunk and start new one
                chunks.append(currentChunk)
                currentChunk = trimmedSentence
            } else {
                // Add sentence to current chunk
                if currentChunk.isEmpty {
                    currentChunk = trimmedSentence
                } else {
                    currentChunk += separator + trimmedSentence
                }
            }

            // Handle case where a single sentence exceeds maxLength
            // (rare, but possible with very long sentences)
            if currentChunk.count > maxLength && chunks.last != currentChunk {
                chunks.append(currentChunk)
                currentChunk = ""
            }
        }

        // Don't forget the last chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    /// Tokenize text into sentences using Apple's NaturalLanguage framework
    private func tokenizeIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            sentences.append(sentence)
            return true
        }

        return sentences
    }

    /// Non-streaming playback - waits for full audio before playing
    private func speakNonStreaming(text: String, apiKey: String) async throws {
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
            let sampleRate = AudioConverter.extractSampleRate(from: mimeType)
            finalAudioData = AudioConverter.createWAVFromPCM(audioData, sampleRate: sampleRate)
            sourceExt = "wav"
        } else {
            finalAudioData = audioData
            sourceExt = "wav"  // Gemini typically returns WAV-compatible format
        }

        // Convert to M4A (AAC) for smaller file size - await completion for Save Audio support
        if let m4aData = await AudioConverter.convertToAAC(inputData: finalAudioData, inputExtension: sourceExt) {
            lastAudioData = m4aData
            _audioFileExtension = "m4a"
        } else {
            // Fallback to original format if conversion fails
            lastAudioData = finalAudioData
            _audioFileExtension = sourceExt
        }

        // Play the audio
        try playbackController.playAudio(data: finalAudioData, fileExtension: sourceExt)
    }

    func pause() {
        if useStreamingMode {
            streamingPlayer.pause()
        } else {
            playbackController.pause()
        }
    }

    func resume() {
        if useStreamingMode {
            streamingPlayer.resume()
        } else {
            playbackController.resume()
        }
    }

    func stop() {
        // Stop WebSocket if active
        isStreamingActive = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        streamingPlayer.stop()
        playbackController.stopPlayback()
    }

    func clearAudioCache() {
        lastAudioData = nil
        accumulatedPCMData = Data()
        _audioFileExtension = "m4a"  // Reset to default
    }

    // MARK: - Gemini-specific Helpers

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

    // MARK: - Audio Processing Helpers

    /// Convert 16-bit PCM audio from big-endian (L16/network order) to little-endian (native)
    private func convertBigEndianToLittleEndian(_ data: Data) -> Data {
        var result = Data(capacity: data.count)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let int16Buffer = buffer.bindMemory(to: UInt16.self)
            for sample in int16Buffer {
                // Swap bytes: big-endian to little-endian
                let swapped = sample.byteSwapped
                withUnsafeBytes(of: swapped) { result.append(contentsOf: $0) }
            }
        }
        return result
    }
}
