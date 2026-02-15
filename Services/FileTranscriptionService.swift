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
            return NSLocalizedString("Audio file not found", comment: "File transcription error")
        case .unsupportedFormat(let format, let supportedFormats):
            return String(format: NSLocalizedString("Unsupported audio format: .%@\n\nSupported formats: %@", comment: "File transcription error"), format, supportedFormats)
        case .fileTooLarge(let maxMB, let actualMB):
            return String(format: NSLocalizedString("File too large (%dMB). Maximum size for this provider is %dMB", comment: "File transcription error"), actualMB, maxMB)
        case .providerNotSupported(let provider):
            return String(format: NSLocalizedString("%@ does not support file transcription.\n\nPlease switch to OpenAI, Gemini, ElevenLabs, or macOS (26+) provider.", comment: "Provider not supported for file transcription"), provider.rawValue)
        case .readError(let error):
            return String(format: NSLocalizedString("Failed to read audio file: %@", comment: "File transcription error"), error.localizedDescription)
        case .transcriptionFailed(let error):
            return String(format: NSLocalizedString("Transcription failed: %@", comment: "File transcription error"), error.localizedDescription)
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

        // Route macOS provider to native speech recognition
        if provider == .macOS {
            return try await transcribeWithMacOS(fileURL: fileURL, language: language)
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

    // MARK: - macOS Native File Transcription

    /// Transcribe using macOS native speech recognition.
    /// On macOS 26+, tries SpeechAnalyzer first, falls back to SFSpeechRecognizer.
    /// On older macOS, uses SFSpeechRecognizer directly.
    private func transcribeWithMacOS(fileURL: URL, language: String?) async throws -> TranscriptionResult {
        let locale = self.locale(for: language)

        // Try SpeechAnalyzer first on macOS 26+
        #if compiler(>=6.1)
        if #available(macOS 26, *) {
            if let result = try await transcribeWithSpeechAnalyzerIfAvailable(fileURL: fileURL, locale: locale) {
                return result
            }
            // SpeechAnalyzer not available for this locale, fall through to SFSpeechRecognizer
        }
        #endif

        // Fallback: SFSpeechRecognizer with SFSpeechURLRecognitionRequest
        return try await transcribeWithSFSpeechRecognizer(fileURL: fileURL, locale: locale)
    }

    /// Build Locale from language code string
    private func locale(for language: String?) -> Locale {
        if let lang = language, !lang.isEmpty,
           let langCode = LanguageCode(rawValue: lang),
           let localeId = langCode.toLocaleIdentifier() {
            return Locale(identifier: localeId)
        }
        // Auto mode: use system locale directly
        // SFSpeechRecognizer accepts Locale.current; SpeechAnalyzer validates separately
        return Locale.current
    }

    // MARK: - SFSpeechRecognizer File Transcription (all macOS versions)

    /// Transcribe using SFSpeechURLRecognitionRequest (supports server-based recognition)
    private func transcribeWithSFSpeechRecognizer(fileURL: URL, locale: Locale) async throws -> TranscriptionResult {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw FileTranscriptionError.transcriptionFailed(
                NSError(domain: "FileTranscription", code: -4, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is not available for \(locale.identifier)"])
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            // Guard against multiple resumptions - the callback can fire multiple times
            // (e.g., error after partial result, or error after isFinal)
            var hasResumed = false

            recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }

                if let error = error {
                    hasResumed = true
                    continuation.resume(throwing: FileTranscriptionError.transcriptionFailed(error))
                    return
                }
                guard let result = result, result.isFinal else { return }
                hasResumed = true
                continuation.resume(returning: TranscriptionResult(text: result.bestTranscription.formattedString))
            }
        }
    }

    // MARK: - SpeechAnalyzer File Transcription (macOS 26+)

    #if compiler(>=6.1)
    /// Try SpeechAnalyzer transcription. Returns nil if model not available for the locale.
    @available(macOS 26, *)
    private func transcribeWithSpeechAnalyzerIfAvailable(fileURL: URL, locale: Locale) async throws -> TranscriptionResult? {
        // Resolve locale to one supported by SpeechTranscriber
        let resolvedLocale = await resolveLocaleForSpeechTranscriber(locale)

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Check if SpeechAnalyzer model is available for this locale
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return nil  // Signal caller to use fallback
        }

        // Open audio file
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw FileTranscriptionError.readError(error)
        }

        let fileFormat = audioFile.processingFormat
        let totalFrames = AVAudioFrameCount(audioFile.length)

        // Create audio converter if formats differ
        var converter: AVAudioConverter?
        if fileFormat != analyzerFormat {
            converter = AVAudioConverter(from: fileFormat, to: analyzerFormat)
            if converter == nil {
                return nil  // Can't convert, use fallback
            }
        }

        // Create AsyncStream to feed audio buffers to the analyzer
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Start results monitoring concurrently
        let resultsTask = Task<String, Error> {
            var accumulatedText = ""
            for try await result in transcriber.results {
                try Task.checkCancellation()

                var currentText = ""
                for char in result.text.characters {
                    currentText.append(char)
                }

                if result.isFinal && !currentText.isEmpty {
                    if accumulatedText.isEmpty {
                        accumulatedText = currentText
                    } else {
                        accumulatedText += " " + currentText
                    }
                }
            }
            return accumulatedText
        }

        // Start the analyzer with input sequence
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            resultsTask.cancel()
            continuation.finish()
            throw FileTranscriptionError.transcriptionFailed(error)
        }

        // Read and feed the audio file in chunks
        let bufferSize: AVAudioFrameCount = 4096
        var framesRead: AVAudioFrameCount = 0
        var bufferError: Error?

        while framesRead < totalFrames {
            if Task.isCancelled {
                bufferError = CancellationError()
                break
            }

            let framesToRead = min(bufferSize, totalFrames - framesRead)
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                bufferError = FileTranscriptionError.readError(
                    NSError(domain: "FileTranscription", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffer"])
                )
                break
            }

            do {
                try audioFile.read(into: readBuffer, frameCount: framesToRead)
            } catch {
                bufferError = FileTranscriptionError.readError(error)
                break
            }

            // Convert if needed
            let bufferToSend: AVAudioPCMBuffer
            if let converter = converter {
                let sampleRateRatio = analyzerFormat.sampleRate / fileFormat.sampleRate
                let outputFrameCapacity = AVAudioFrameCount(Double(readBuffer.frameLength) * sampleRateRatio)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outputFrameCapacity) else {
                    bufferError = FileTranscriptionError.readError(
                        NSError(domain: "FileTranscription", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate conversion buffer"])
                    )
                    break
                }

                var convertError: NSError?
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return readBuffer
                }
                converter.convert(to: outputBuffer, error: &convertError, withInputFrom: inputBlock)

                if let convertError = convertError {
                    bufferError = FileTranscriptionError.readError(convertError)
                    break
                }
                bufferToSend = outputBuffer
            } else {
                bufferToSend = readBuffer
            }

            let input = AnalyzerInput(buffer: bufferToSend)
            continuation.yield(input)

            framesRead += framesToRead
        }

        // Signal end of input
        continuation.finish()

        // If buffer processing failed, clean up and throw
        if let bufferError = bufferError {
            resultsTask.cancel()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            throw bufferError is FileTranscriptionError ? bufferError : FileTranscriptionError.transcriptionFailed(bufferError)
        }

        // Wait for analyzer to finalize
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            resultsTask.cancel()
            throw FileTranscriptionError.transcriptionFailed(error)
        }

        // Wait for results
        let fullText: String
        do {
            fullText = try await resultsTask.value
        } catch is CancellationError {
            throw FileTranscriptionError.transcriptionFailed(
                NSError(domain: "FileTranscription", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transcription cancelled"])
            )
        } catch {
            throw FileTranscriptionError.transcriptionFailed(error)
        }

        return TranscriptionResult(text: fullText)
    }
    /// Resolve a locale to one supported by SpeechTranscriber.
    /// If the given locale is already supported, returns it as-is.
    /// Otherwise, finds the best match from supported locales by language code.
    @available(macOS 26, *)
    private func resolveLocaleForSpeechTranscriber(_ locale: Locale) async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let langCode = locale.language.languageCode?.identifier ?? "en"

        // Check if exact locale is supported
        if supported.contains(where: { $0.identifier == locale.identifier }) {
            return locale
        }

        // Find match by language+region
        if let region = locale.region?.identifier,
           let match = supported.first(where: {
               $0.language.languageCode?.identifier == langCode &&
               $0.region?.identifier == region
           }) {
            return match
        }

        // Find match by language only
        if let match = supported.first(where: {
            $0.language.languageCode?.identifier == langCode
        }) {
            return match
        }

        return Locale(identifier: "en-US")
    }
    #endif
}
