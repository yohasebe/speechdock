import Foundation
import Speech
@preconcurrency import AVFoundation

/// Error types for file transcription
enum FileTranscriptionError: LocalizedError {
    case fileNotFound
    case unsupportedFormat(String, supportedFormats: String)
    case fileTooLarge(maxMB: Int, actualMB: Int)
    case providerNotSupported(RealtimeSTTProvider)
    case readError(Error)
    case transcriptionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Audio file not found"
        case .unsupportedFormat(let format, let supportedFormats):
            return "Unsupported audio format: .\(format)\n\nSupported formats: \(supportedFormats)"
        case .fileTooLarge(let maxMB, let actualMB):
            return "File too large (\(actualMB)MB). Maximum size for this provider is \(maxMB)MB"
        case .providerNotSupported(let provider):
            return "\(provider.rawValue) does not support file transcription.\n\nPlease switch to OpenAI, Gemini, ElevenLabs, or macOS (26+) provider."
        case .readError(let error):
            return "Failed to read audio file: \(error.localizedDescription)"
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        }
    }
}

/// Service for transcribing audio files
@MainActor
final class FileTranscriptionService {
    static let shared = FileTranscriptionService()

    /// Supported audio file extensions (union of all providers)
    private let supportedExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "aiff", "webm", "ogg", "flac", "mp4"]

    private init() {}

    /// Validate and transcribe an audio file
    /// - Parameters:
    ///   - fileURL: URL of the audio file
    ///   - provider: STT provider to use
    ///   - language: Optional language code
    /// - Returns: Transcription result
    func transcribe(
        fileURL: URL,
        provider: RealtimeSTTProvider,
        language: String?
    ) async throws -> TranscriptionResult {
        // Validate provider supports file transcription
        guard provider.supportsFileTranscription else {
            throw FileTranscriptionError.providerNotSupported(provider)
        }

        // Validate file with provider-specific limits
        try validateFile(fileURL, for: provider)

        // Route macOS provider to SpeechAnalyzer (local processing, no API client needed)
        if provider == .macOS {
            #if compiler(>=6.1)
            if #available(macOS 26, *) {
                return try await transcribeWithSpeechAnalyzer(fileURL: fileURL, language: language)
            }
            #endif
            throw FileTranscriptionError.providerNotSupported(provider)
        }

        // Read file data
        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            throw FileTranscriptionError.readError(error)
        }

        // Get the appropriate STT model for the provider
        let model = defaultModel(for: provider)

        // Create API client and transcribe
        let client = apiClient(for: provider)

        do {
            return try await client.transcribe(
                audioData: audioData,
                model: model,
                language: language?.isEmpty == true ? nil : language
            )
        } catch {
            throw FileTranscriptionError.transcriptionFailed(error)
        }
    }

    /// Validate file format and size for a specific provider
    /// - Parameters:
    ///   - url: File URL to validate
    ///   - provider: The provider to validate against
    func validateFile(_ url: URL, for provider: RealtimeSTTProvider) throws {
        // Check file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileTranscriptionError.fileNotFound
        }

        // Check extension
        let fileExtension = url.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw FileTranscriptionError.unsupportedFormat(fileExtension, supportedFormats: provider.supportedAudioFormats)
        }

        // Check file size against provider-specific limit
        let maxFileSize = provider.maxFileSizeMB * 1024 * 1024
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int {
                if fileSize > maxFileSize {
                    let actualMB = fileSize / (1024 * 1024)
                    throw FileTranscriptionError.fileTooLarge(maxMB: provider.maxFileSizeMB, actualMB: actualMB)
                }
            }
        } catch let error as FileTranscriptionError {
            throw error
        } catch {
            throw FileTranscriptionError.readError(error)
        }
    }

    /// Get default STT model for file transcription
    private func defaultModel(for provider: RealtimeSTTProvider) -> STTModel {
        switch provider {
        case .openAI:
            return .whisper1  // whisper-1 is best for file transcription
        case .gemini:
            return .gemini25Flash
        case .elevenLabs:
            return .scribeV2
        case .grok, .macOS:
            // These don't support file transcription
            return .whisper1
        }
    }

    /// Create API client for provider
    private func apiClient(for provider: RealtimeSTTProvider) -> STTAPIClient {
        switch provider {
        case .openAI:
            return OpenAISTTClient()
        case .gemini:
            return GeminiSTTClient()
        case .elevenLabs:
            return ElevenLabsSTTClient()
        case .grok, .macOS:
            // Return OpenAI as fallback (shouldn't be called due to validation)
            return OpenAISTTClient()
        }
    }

    // MARK: - SpeechAnalyzer File Transcription (macOS 26+)

    #if compiler(>=6.1)
    @available(macOS 26, *)
    private func transcribeWithSpeechAnalyzer(fileURL: URL, language: String?) async throws -> TranscriptionResult {
        // Create locale based on selected language
        let locale: Locale
        if let lang = language, !lang.isEmpty,
           let langCode = LanguageCode(rawValue: lang),
           let localeId = langCode.toLocaleIdentifier() {
            locale = Locale(identifier: localeId)
        } else {
            locale = Locale.current
        }

        // Create transcriber with no volatile/fast results — we only need final results for file transcription
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // Open audio file
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw FileTranscriptionError.readError(error)
        }

        // Create analyzer and start file transcription
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        do {
            try await analyzer.start(inputAudioFile: audioFile)
        } catch {
            throw FileTranscriptionError.transcriptionFailed(error)
        }

        // Collect all final results
        var segments: [String] = []

        do {
            for try await result in transcriber.results {
                try Task.checkCancellation()

                guard result.isFinal else { continue }

                // Extract text from AttributedString (char-by-char pattern from SpeechAnalyzerSTT)
                var currentText = ""
                for char in result.text.characters {
                    currentText.append(char)
                }

                if !currentText.isEmpty {
                    segments.append(currentText)
                }
            }
        } catch is CancellationError {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            throw FileTranscriptionError.transcriptionFailed(
                NSError(domain: "FileTranscription", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transcription cancelled"])
            )
        } catch {
            throw FileTranscriptionError.transcriptionFailed(error)
        }

        let fullText = segments.joined(separator: " ")
        return TranscriptionResult(text: fullText)
    }
    #endif
}
