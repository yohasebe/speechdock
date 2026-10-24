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
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            let appState = AppState.shared
            let provider = appState.selectedTTSProvider

            if provider.requiresAPIKey {
                guard let envKeyName = provider.envKeyName,
                      APIKeyManager.shared.hasAPIKey(for: envKeyName) else {
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
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            AppState.shared.stopTTS()
            self.resumeExecution(withResult: nil)
        }

        return nil
    }
}

// MARK: - Pause Speaking Command

class PauseSpeakingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

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
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

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

        // MP3 is only written as the provider produced it; checked again once the format is known
        let requestedExtension = (expandedPath as NSString).pathExtension.lowercased()
        guard requestedExtension.isEmpty || requestedExtension == "mp3"
                || AudioConverter.writableExtensions.contains(requestedExtension) else {
            setAppleScriptError(.ttsSavePathInvalid,
                message: "Cannot save audio as .\(requestedExtension). Use .mp3, .m4a, .wav, .aiff or .caf.")
            return nil
        }

        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            let appState = AppState.shared
            let provider = appState.selectedTTSProvider

            if provider.requiresAPIKey {
                guard let envKeyName = provider.envKeyName,
                      APIKeyManager.shared.hasAPIKey(for: envKeyName) else {
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

                let sourceExtension = saveService.audioFileExtension
                let outputData: Data
                switch AudioConverter.savePlan(sourceExtension: sourceExtension, requestedExtension: requestedExtension) {
                case .writeAsIs:
                    outputData = audioData
                case .convert:
                    let converted = await Task.detached {
                        AudioConverter.convert(audioData, from: sourceExtension, to: requestedExtension)
                    }.value
                    guard let converted, !converted.isEmpty else {
                        saveService.clearAudioCache()
                        self.setAppleScriptError(.ttsSaveFailed, message: "Failed to convert the audio to .\(requestedExtension).")
                        self.resumeExecution(withResult: nil)
                        return
                    }
                    outputData = converted
                case .unsupported:
                    saveService.clearAudioCache()
                    let usable = ([sourceExtension] + ["m4a", "wav", "aiff", "caf"].filter { $0 != sourceExtension })
                        .map { "." + $0 }.joined(separator: ", ")
                    self.setAppleScriptError(.ttsSavePathInvalid,
                        message: "\(provider.rawValue) produces .\(sourceExtension) audio, which cannot be saved as .\(requestedExtension). Use one of \(usable).")
                    self.resumeExecution(withResult: nil)
                    return
                }

                let fileURL = URL(fileURLWithPath: expandedPath)
                try outputData.write(to: fileURL)

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
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            AppState.shared.toggleShortcutHUD()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

// MARK: - Show Quick Transcription Command

class ShowQuickTranscriptionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            let appState = AppState.shared
            let manager = FloatingMicButtonManager.shared

            // Show floating mic button if not visible (without starting recording)
            if !appState.showFloatingMicButton {
                appState.showFloatingMicButton = true
                manager.show(appState: appState)
            }

            self.resumeExecution(withResult: nil)
        }

        return nil
    }
}

// MARK: - Start Quick Transcription Command

class StartQuickTranscriptionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

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
                      APIKeyManager.shared.hasAPIKey(for: envKeyName) else {
                    let envName = provider.envKeyName ?? "API_KEY"
                    self.setAppleScriptError(.apiKeyNotConfigured,
                        message: "No API key configured for \(provider.rawValue). Set the \(envName) environment variable or configure it in Settings.")
                    self.resumeExecution(withResult: nil)
                    return
                }
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

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
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            let appState = AppState.shared
            let manager = FloatingMicButtonManager.shared

            // Check if recording
            if !appState.isRecording && appState.transcriptionState != .preparing {
                self.setAppleScriptError(.sttNotRecording,
                    message: "Quick transcription is not currently recording.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Stop recording
            let transcribedText = await manager.stopRecordingAndWait()
            self.resumeExecution(withResult: transcribedText)
        }

        return nil
    }
}

// MARK: - Toggle Quick Transcription Command

class ToggleQuickTranscriptionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            AppState.shared.toggleQuickTranscription()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

// MARK: - Show STT Panel Command

class ShowSTTPanelCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            AppState.shared.showSTTPanel()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

// MARK: - Toggle STT Panel Command

class ToggleSTTPanelCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            AppState.shared.toggleSTTPanelVisibility()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

// MARK: - Show TTS Panel Command

class ShowTTSPanelCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            AppState.shared.showTTSPanel()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

// MARK: - Toggle TTS Panel Command

class ToggleTTSPanelCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            AppState.shared.toggleTTSPanelVisibility()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

// MARK: - Show Subtitle Command

class ShowSubtitleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            AppState.shared.showSubtitleMode()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

// MARK: - Toggle Subtitle Command

class ToggleSubtitleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            AppState.shared.toggleSubtitleMode()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

// MARK: - Start OCR Command

class StartOCRCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()

        Task { @MainActor in
            // Wait for app initialization
            let initialized = await self.waitForInitialization(timeout: 5.0)
            guard initialized else {
                self.setAppleScriptError(.appNotInitialized,
                    message: "SpeechDock is still initializing. Please try again in a moment.")
                self.resumeExecution(withResult: nil)
                return
            }

            // Ensure app is activated when called from AppleScript (needed for windows to appear)
            NSApp.activate(ignoringOtherApps: true)
            // Small delay to ensure activation completes
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            AppState.shared.startOCR()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

class HideSTTPanelCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()
        Task { @MainActor in
            guard await self.waitForInitialization(timeout: 5) else {
                self.setAppleScriptError(.appNotInitialized, message: "SpeechDock is still initializing.")
                self.resumeExecution(withResult: nil)
                return
            }
            AppState.shared.hideSTTPanel()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

class HideTTSPanelCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()
        Task { @MainActor in
            guard await self.waitForInitialization(timeout: 5) else {
                self.setAppleScriptError(.appNotInitialized, message: "SpeechDock is still initializing.")
                self.resumeExecution(withResult: nil)
                return
            }
            AppState.shared.hideTTSPanel()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}

class HideSubtitleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        suspendExecution()
        Task { @MainActor in
            guard await self.waitForInitialization(timeout: 5) else {
                self.setAppleScriptError(.appNotInitialized, message: "SpeechDock is still initializing.")
                self.resumeExecution(withResult: nil)
                return
            }
            AppState.shared.hideSubtitleMode()
            self.resumeExecution(withResult: nil)
        }
        return nil
    }
}
