import Foundation

final class ElevenLabsSTTClient: STTAPIClient {
    private let endpoint = "https://api.elevenlabs.io/v1/speech-to-text"
    private let apiKeyManager: APIKeyManager

    init(apiKeyManager: APIKeyManager = .shared) {
        self.apiKeyManager = apiKeyManager
    }

    func transcribe(
        audioData: Data,
        model: STTModel,
        language: String?
    ) async throws -> TranscriptionResult {
        guard let apiKey = apiKeyManager.getAPIKey(for: .elevenLabs) else {
            throw STTError.invalidAPIKey
        }

        let format = AudioFormatConverter.normalizeFormat(audioData)
        let boundary = UUID().uuidString
        var body = Data()

        // Add model_id field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n")
        body.append("\(model.rawValue)\r\n")

        // Add file field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(format.fileExtension)\"\r\n")
        body.append("Content-Type: \(format.mimeType)\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        // Add file_format field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file_format\"\r\n\r\n")
        body.append("other\r\n")

        // Add timestamps_granularity field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"timestamps_granularity\"\r\n\r\n")
        body.append("word\r\n")

        // Add language_code if specified
        if let lang = language, lang != "auto" {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"language_code\"\r\n\r\n")
            body.append("\(lang)\r\n")
        }

        body.append("--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.networkError(URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw STTError.apiError("ElevenLabs API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        let json = try JSONDecoder().decode(ElevenLabsResponse.self, from: data)

        let confidence: Double?
        if let words = json.words, !words.isEmpty {
            let logprobs = words.compactMap { $0.logprob }
            if !logprobs.isEmpty {
                let avgLogprob = logprobs.reduce(0, +) / Double(logprobs.count)
                confidence = exp(avgLogprob)
            } else {
                confidence = nil
            }
        } else {
            confidence = json.languageProbability
        }

        return TranscriptionResult(
            text: json.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence,
            languageCode: json.languageCode
        )
    }
}

private struct ElevenLabsResponse: Decodable {
    let text: String
    let languageCode: String?
    let languageProbability: Double?
    let words: [WordEntry]?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
        case languageProbability = "language_probability"
        case words
    }

    struct WordEntry: Decodable {
        let text: String
        let start: Double?
        let end: Double?
        let logprob: Double?
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
