import AppKit

// MARK: - Speak Text Command

class SpeakTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            setAppleScriptError(.ttsEmptyText, message: "Cannot speak empty text. Provide a non-empty string.")
            return nil
        }

        return MainActor.assumeIsolated {
            let appState = AppState.shared
            let provider = appState.selectedTTSProvider

            if provider.requiresAPIKey {
                guard let envKeyName = provider.envKeyName,
                      APIKeyManager.shared.getAPIKey(for: envKeyName) != nil else {
                    let envName = provider.envKeyName ?? "API_KEY"
                    setAppleScriptError(.apiKeyNotConfigured,
                        message: "No API key configured for \(provider.rawValue). Set the \(envName) environment variable or configure it in Settings.")
                    return nil
                }
            }

            appState.ttsText = text
            appState.speakCurrentText()
            return nil
        }
    }
}

// MARK: - Stop Speaking Command

class StopSpeakingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            AppState.shared.stopTTS()
        }
        return nil
    }
}

// MARK: - Pause Speaking Command

class PauseSpeakingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        return MainActor.assumeIsolated {
            let appState = AppState.shared

            guard appState.ttsState == .speaking else {
                setAppleScriptError(.ttsNotSpeaking, message: "Cannot pause: TTS is not currently speaking.")
                return nil
            }

            appState.pauseResumeTTS()
            return nil
        }
    }
}

// MARK: - Resume Speaking Command

class ResumeSpeakingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        return MainActor.assumeIsolated {
            let appState = AppState.shared

            guard appState.ttsState == .paused else {
                setAppleScriptError(.ttsNotPaused, message: "Cannot resume: TTS is not currently paused.")
                return nil
            }

            appState.pauseResumeTTS()
            return nil
        }
    }
}

// MARK: - Save Audio Command

class SaveAudioCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            setAppleScriptError(.ttsEmptyText, message: "Cannot save audio for empty text. Provide a non-empty string.")
            return nil
        }

        guard text.count >= 5 else {
            setAppleScriptError(.ttsTextTooShort, message: "Text must be at least 5 characters long for audio synthesis.")
            return nil
        }

        guard let filePath = evaluatedArguments?["toFile"] as? String, !filePath.isEmpty else {
            setAppleScriptError(.ttsSavePathInvalid, message: "A file path is required. Use: save audio \"text\" to file \"/path/to/output.mp3\"")
            return nil
        }

        let expandedPath = NSString(string: filePath).expandingTildeInPath
        let directoryPath = (expandedPath as NSString).deletingLastPathComponent

        guard FileManager.default.fileExists(atPath: directoryPath) else {
            setAppleScriptError(.ttsSaveDirectoryNotFound,
                message: "Directory not found: \(directoryPath). Ensure the parent directory exists.")
            return nil
        }

        let provider: TTSProvider = MainActor.assumeIsolated {
            AppState.shared.selectedTTSProvider
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

        suspendExecution()

        Task { @MainActor in
            let appState = AppState.shared
            let saveService = TTSFactory.makeService(for: appState.selectedTTSProvider)
            saveService.selectedVoice = appState.selectedTTSVoice
            if !appState.selectedTTSModel.isEmpty {
                saveService.selectedModel = appState.selectedTTSModel
            }
            saveService.selectedSpeed = appState.selectedTTSSpeed
            if !appState.selectedTTSLanguage.isEmpty {
                saveService.selectedLanguage = appState.selectedTTSLanguage
            }
            saveService.useStreamingMode = false

            do {
                let processedText = TextReplacementService.shared.applyReplacements(to: text)
                try await saveService.speak(text: processedText)
                saveService.stop()

                guard let audioData = saveService.lastAudioData, !audioData.isEmpty else {
                    self.setAppleScriptError(.ttsSaveFailed, message: "Audio synthesis produced no data.")
                    self.resumeExecution(withResult: nil)
                    return
                }

                let fileURL = URL(fileURLWithPath: expandedPath)
                try audioData.write(to: fileURL)

                saveService.clearAudioCache()
                self.resumeExecution(withResult: expandedPath)
            } catch {
                saveService.stop()
                saveService.clearAudioCache()
                self.setAppleScriptError(.ttsSaveFailed, message: "Failed to save audio: \(error.localizedDescription)")
                self.resumeExecution(withResult: nil)
            }
        }

        return nil
    }
}
