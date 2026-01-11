import Foundation

struct TranscriptionResult {
    let text: String
    let confidence: Double?
    let languageCode: String?

    init(text: String, confidence: Double? = nil, languageCode: String? = nil) {
        self.text = text
        self.confidence = confidence
        self.languageCode = languageCode
    }
}

enum STTError: LocalizedError {
    case invalidAPIKey
    case networkError(Error)
    case apiError(String)
    case unsupportedFormat
    case emptyResponse
    case microphonePermissionDenied
    case recordingFailed(Error)
    case providerUnavailable(STTProvider)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "API key is missing or invalid. Please check your settings."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .unsupportedFormat:
            return "Audio format is not supported."
        case .emptyResponse:
            return "No transcription was returned."
        case .microphonePermissionDenied:
            return "Microphone access is required. Please enable in System Settings."
        case .recordingFailed(let error):
            return "Recording failed: \(error.localizedDescription)"
        case .providerUnavailable(let provider):
            return "\(provider.rawValue) is currently unavailable."
        }
    }
}
