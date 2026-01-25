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

        let fileURL = URL(fileURLWithPath: expandedPath)

        suspendExecution()

        Task { @MainActor in
            let appState = AppState.shared
            let provider = appState.selectedRealtimeProvider
            let language = appState.selectedSTTLanguage.isEmpty ? nil : appState.selectedSTTLanguage

            guard provider.supportsFileTranscription else {
                self.setAppleScriptError(.sttProviderNotSupported,
                    message: "\(provider.rawValue) does not support file transcription. Switch to OpenAI, Gemini, or ElevenLabs.")
                self.resumeExecution(withResult: nil)
                return
            }

            if provider.requiresAPIKey {
                guard let envKeyName = provider.envKeyName,
                      APIKeyManager.shared.getAPIKey(for: envKeyName) != nil else {
                    let envName = provider.envKeyName ?? "API_KEY"
                    self.setAppleScriptError(.apiKeyNotConfigured,
                        message: "No API key configured for \(provider.rawValue). Set the \(envName) environment variable or configure it in Settings.")
                    self.resumeExecution(withResult: nil)
                    return
                }
            }

            guard !appState.isRecording else {
                self.setAppleScriptError(.sttAlreadyRecording,
                    message: "Cannot transcribe file while recording is in progress. Stop recording first.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Validate file format and size
            do {
                try FileTranscriptionService.shared.validateFile(fileURL, for: provider)
            } catch let error as FileTranscriptionError {
                switch error {
                case .unsupportedFormat(let format, let supportedFormats):
                    self.setAppleScriptError(.sttUnsupportedFormat,
                        message: "Unsupported audio format: .\(format). Supported formats for \(provider.rawValue): \(supportedFormats)")
                case .fileTooLarge(let maxMB, let actualMB):
                    self.setAppleScriptError(.sttFileTooLarge,
                        message: "File too large (\(actualMB)MB). Maximum for \(provider.rawValue) is \(maxMB)MB.")
                default:
                    self.setAppleScriptError(.sttTranscriptionFailed, message: error.localizedDescription)
                }
                self.resumeExecution(withResult: nil)
                return
            } catch {
                self.setAppleScriptError(.sttTranscriptionFailed, message: error.localizedDescription)
                self.resumeExecution(withResult: nil)
                return
            }

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
}
