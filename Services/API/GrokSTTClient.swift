import Foundation

/// File transcription via xAI's speech-to-text REST API (`POST /v1/stt`).
final class GrokSTTClient: STTAPIClient {
    private let endpoint = "https://api.x.ai/v1/stt"
    private let apiKeyManager: APIKeyManager

    init(apiKeyManager: APIKeyManager = .shared) {
        self.apiKeyManager = apiKeyManager
    }

    func transcribe(
        audioData: Data,
        model: STTModel,
        language: String?,
        originalExtension: String? = nil
    ) async throws -> TranscriptionResult {
        guard let apiKey = await apiKeyManager.apiKey(for: .grok) else {
            throw STTError.apiError(apiKeyManager.unavailableReason(for: .grok))
        }

        let format = AudioFormatConverter.normalizeFormat(audioData, originalExtension: originalExtension)
        let boundary = UUID().uuidString
        let body = Self.multipartBody(
            audioData: audioData,
            fileExtension: format.fileExtension,
            mimeType: format.mimeType,
            language: language,
            boundary: boundary
        )

        guard let url = URL(string: endpoint) else {
            throw STTError.apiError("Invalid API endpoint URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 180

        let (data, _) = try await STTAPIHelper.performRequest(request, providerName: "Grok")
        let json = try JSONDecoder().decode(GrokTranscriptionResponse.self, from: data)

        return TranscriptionResult(
            text: json.text.trimmingCharacters(in: .whitespacesAndNewlines),
            languageCode: json.language
        )
    }

    /// The API reads option fields only when they precede `file`, so the file
    /// goes last. Without `language` the model detects the language itself.
    static func multipartBody(
        audioData: Data,
        fileExtension: String,
        mimeType: String,
        language: String?,
        boundary: String
    ) -> Data {
        var body = Data()

        if let lang = language, !lang.isEmpty, lang != "auto" {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.append("\(lang)\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(fileExtension)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        return body
    }
}

struct GrokTranscriptionResponse: Decodable {
    let text: String
    let language: String?
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
