import AppKit

// MARK: - Transcribe File Command

class TranscribeFileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let filePath = directParameter as? String, !filePath.isEmpty else {
            setAppleScriptError(.sttFileNotFound, message: "A file path is required. Use: transcribe file \"/path/to/audio.mp3\"")
            return nil
        }

        let expandedPath = NSString(string: filePath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            setAppleScriptError(.sttFileNotFound, message: "File not found: \(expandedPath)")
            return nil
        }

        let (provider, language, isRecording): (RealtimeSTTProvider, String?, Bool) = MainActor.assumeIsolated {
            let appState = AppState.shared
            let lang = appState.selectedSTTLanguage.isEmpty ? nil : appState.selectedSTTLanguage
            return (appState.selectedRealtimeProvider, lang, appState.isRecording)
        }

        guard provider.supportsFileTranscription else {
            setAppleScriptError(.sttProviderNotSupported,
                message: "\(provider.rawValue) does not support file transcription. Switch to OpenAI, Gemini, or ElevenLabs.")
            return nil
        }

        if provider.requiresAPIKey {
            guard let envKeyName = provider.envKeyName,
                  APIKeyManager.shared.getAPIKey(for: envKeyName) != nil else {
                let envName = provider.envKeyName ?? "API_KEY"
                setAppleScriptError(.apiKeyNotConfigured,
                    message: "No API key configured for \(provider.rawValue). Set the \(envName) environment variable or configure it in Settings.")
                return nil
            }
        }

        guard !isRecording else {
            setAppleScriptError(.sttAlreadyRecording,
                message: "Cannot transcribe file while recording is in progress. Stop recording first.")
            return nil
        }

        let fileURL = URL(fileURLWithPath: expandedPath)

        // Validate file format and size (FileTranscriptionService.validateFile is @MainActor)
        let validationError: ValidationError? = MainActor.assumeIsolated {
            do {
                try FileTranscriptionService.shared.validateFile(fileURL, for: provider)
                return nil
            } catch let error as FileTranscriptionError {
                switch error {
                case .unsupportedFormat(let format, let supportedFormats):
                    return .init(code: .sttUnsupportedFormat,
                        message: "Unsupported audio format: .\(format). Supported formats for \(provider.rawValue): \(supportedFormats)")
                case .fileTooLarge(let maxMB, let actualMB):
                    return .init(code: .sttFileTooLarge,
                        message: "File too large (\(actualMB)MB). Maximum for \(provider.rawValue) is \(maxMB)MB.")
                default:
                    return .init(code: .sttTranscriptionFailed, message: error.localizedDescription)
                }
            } catch {
                return .init(code: .sttTranscriptionFailed, message: error.localizedDescription)
            }
        }

        if let validationError {
            setAppleScriptError(validationError.code, message: validationError.message)
            return nil
        }

        suspendExecution()

        Task { @MainActor in
            do {
                let result = try await FileTranscriptionService.shared.transcribe(
                    fileURL: fileURL,
                    provider: provider,
                    language: language
                )
                self.resumeExecution(withResult: result.text)
            } catch {
                self.setAppleScriptError(.sttTranscriptionFailed,
                    message: "Transcription failed: \(error.localizedDescription)")
                self.resumeExecution(withResult: nil)
            }
        }

        return nil
    }

    /// Helper struct for passing validation errors out of MainActor.assumeIsolated
    struct ValidationError {
        let code: AppleScriptErrorCode
        let message: String
    }
}
