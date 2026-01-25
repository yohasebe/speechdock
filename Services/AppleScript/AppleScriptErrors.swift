import Foundation

/// Error codes for AppleScript commands (1000-1099)
enum AppleScriptErrorCode: Int {
    // General
    case internalError = 1000
    case invalidParameter = 1001

    // TTS (1010-1019)
    case ttsEmptyText = 1010
    case ttsNotSpeaking = 1011
    case ttsNotPaused = 1012
    case ttsAlreadySpeaking = 1013
    case ttsProviderError = 1014
    case ttsSavePathInvalid = 1015
    case ttsSaveDirectoryNotFound = 1016
    case ttsSaveFailed = 1017
    case ttsTextTooShort = 1018

    // STT (1020-1029)
    case sttProviderNotSupported = 1020
    case sttFileNotFound = 1021
    case sttUnsupportedFormat = 1022
    case sttFileTooLarge = 1023
    case sttAlreadyRecording = 1024
    case sttTranscriptionFailed = 1025
    case sttNotRecording = 1026

    // Translation (1030-1039)
    case translationEmptyText = 1030
    case translationInvalidLanguage = 1031
    case translationFailed = 1032
    case translationProviderUnavailable = 1033

    // Provider/Settings (1040-1049)
    case invalidProviderName = 1040
    case invalidSpeed = 1042
    case apiKeyNotConfigured = 1043

    // Clipboard (1050-1059)
    case clipboardEmptyText = 1050
    case clipboardPasteFailed = 1051
}

extension NSScriptCommand {
    /// Set a script error with the given code and message
    func setAppleScriptError(_ code: AppleScriptErrorCode, message: String) {
        scriptErrorNumber = code.rawValue
        scriptErrorString = message
    }
}
