import AppKit

// MARK: - Speak Text Command

class SpeakTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            setAppleScriptError(.ttsEmptyText, message: "Cannot speak empty text. Provide a non-empty string.")
            return nil
        }

        suspendExecution()

        Task { @MainActor in
            let appState = AppState.shared
            let provider = appState.selectedTTSProvider

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

            appState.ttsText = text
            appState.speakCurrentText()
            self.resumeExecution(withResult: nil)
        }

        return nil
    }
}

// MARK: - Stop Speaking Command

class StopSpeakingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        DispatchQueue.main.async {
            AppState.shared.stopTTS()
        }
        return nil
    }
}

// MARK: - Pause Speaking Command

class PauseSpeakingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            let appState = AppState.shared

            guard appState.ttsState == .speaking else {
                self.setAppleScriptError(.ttsNotSpeaking, message: "Cannot pause: TTS is not currently speaking.")
                self.resumeExecution(withResult: nil)
                return
            }

            appState.pauseResumeTTS()
            self.resumeExecution(withResult: nil)
        }

        return nil
    }
}

// MARK: - Resume Speaking Command

class ResumeSpeakingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            let appState = AppState.shared

            guard appState.ttsState == .paused else {
                self.setAppleScriptError(.ttsNotPaused, message: "Cannot resume: TTS is not currently paused.")
                self.resumeExecution(withResult: nil)
                return
            }

            appState.pauseResumeTTS()
            self.resumeExecution(withResult: nil)
        }

        return nil
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

        suspendExecution()

        Task { @MainActor in
            let appState = AppState.shared
            let provider = appState.selectedTTSProvider

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

// MARK: - Show Shortcuts Command

class ShowShortcutsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        DispatchQueue.main.async {
            AppState.shared.toggleShortcutHUD()
        }
        return nil
    }
}

// MARK: - Start Quick Transcription Command

class StartQuickTranscriptionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            let appState = AppState.shared
            let manager = FloatingMicButtonManager.shared

            // Check if already recording
            if appState.isRecording {
                self.setAppleScriptError(.sttAlreadyRecording,
                    message: "Quick transcription is already recording. Use 'stop quick transcription' to stop.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Check API key if needed
            let provider = appState.selectedRealtimeProvider
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

            // Show floating mic button if not visible
            if !appState.showFloatingMicButton {
                appState.showFloatingMicButton = true
                manager.show(appState: appState)
            }

            // Start recording
            manager.startRecording()
            self.resumeExecution(withResult: nil)
        }

        return nil
    }
}

// MARK: - Stop Quick Transcription Command

class StopQuickTranscriptionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            let appState = AppState.shared
            let manager = FloatingMicButtonManager.shared

            // Check if recording
            if !appState.isRecording {
                self.setAppleScriptError(.sttNotRecording,
                    message: "Quick transcription is not currently recording.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Stop recording
            manager.stopRecording()

            // Return the transcribed text
            let transcribedText = appState.currentTranscription
            self.resumeExecution(withResult: transcribedText.isEmpty ? nil : transcribedText)
        }

        return nil
    }
}

// MARK: - Toggle Quick Transcription Command

class ToggleQuickTranscriptionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        DispatchQueue.main.async {
            AppState.shared.toggleQuickTranscription()
        }
        return nil
    }
}
