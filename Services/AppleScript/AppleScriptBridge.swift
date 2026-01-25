import AppKit
import os.log

private let logger = Logger(subsystem: "com.speechdock.app", category: "AppleScript")

// MARK: - NSApplication KVC Properties for AppleScript

extension NSApplication {

    // MARK: TTS Provider

    @objc var scriptTTSProvider: String {
        get {
            MainActor.assumeIsolated {
                AppState.shared.selectedTTSProvider.rawValue
            }
        }
        set {
            MainActor.assumeIsolated {
                guard let provider = TTSProvider(rawValue: newValue) else {
                    logger.warning("Invalid TTS provider name: \(newValue, privacy: .public). Valid values: \(TTSProvider.allCases.map { $0.rawValue }.joined(separator: ", "), privacy: .public)")
                    return
                }
                AppState.shared.selectedTTSProvider = provider
            }
        }
    }

    // MARK: TTS Voice

    @objc var scriptTTSVoice: String {
        get {
            MainActor.assumeIsolated {
                AppState.shared.selectedTTSVoice
            }
        }
        set {
            MainActor.assumeIsolated {
                AppState.shared.selectedTTSVoice = newValue
            }
        }
    }

    // MARK: TTS Speed

    @objc var scriptTTSSpeed: Double {
        get {
            MainActor.assumeIsolated {
                AppState.shared.selectedTTSSpeed
            }
        }
        set {
            MainActor.assumeIsolated {
                let clampedSpeed = min(max(newValue, 0.25), 4.0)
                AppState.shared.selectedTTSSpeed = clampedSpeed
            }
        }
    }

    // MARK: STT Provider

    @objc var scriptSTTProvider: String {
        get {
            MainActor.assumeIsolated {
                AppState.shared.selectedRealtimeProvider.rawValue
            }
        }
        set {
            MainActor.assumeIsolated {
                guard let provider = RealtimeSTTProvider(rawValue: newValue) else {
                    logger.warning("Invalid STT provider name: \(newValue, privacy: .public). Valid values: \(RealtimeSTTProvider.allCases.map { $0.rawValue }.joined(separator: ", "), privacy: .public)")
                    return
                }
                AppState.shared.selectedRealtimeProvider = provider
            }
        }
    }

    // MARK: Translation Provider

    @objc var scriptTranslationProvider: String {
        get {
            MainActor.assumeIsolated {
                AppState.shared.translationProvider.rawValue
            }
        }
        set {
            MainActor.assumeIsolated {
                guard let provider = TranslationProvider(rawValue: newValue) else {
                    logger.warning("Invalid translation provider name: \(newValue, privacy: .public). Valid values: \(TranslationProvider.allCases.map { $0.rawValue }.joined(separator: ", "), privacy: .public)")
                    return
                }
                AppState.shared.translationProvider = provider
            }
        }
    }

    // MARK: Read-only State

    @objc var scriptIsSpeaking: Bool {
        MainActor.assumeIsolated {
            AppState.shared.ttsState == .speaking || AppState.shared.ttsState == .paused
        }
    }

    @objc var scriptIsRecording: Bool {
        MainActor.assumeIsolated {
            AppState.shared.isRecording
        }
    }

    // MARK: Quick Transcription State

    @objc var scriptShowQuickTranscription: Bool {
        get {
            MainActor.assumeIsolated {
                AppState.shared.showFloatingMicButton
            }
        }
        set {
            MainActor.assumeIsolated {
                if newValue != AppState.shared.showFloatingMicButton {
                    AppState.shared.toggleFloatingMicButton()
                }
            }
        }
    }
}
