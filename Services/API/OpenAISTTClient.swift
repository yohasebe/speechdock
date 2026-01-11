import Foundation

final class OpenAISTTClient: STTAPIClient {
    private let endpoint = "https://api.openai.com/v1/audio/transcriptions"
    private let apiKeyManager: APIKeyManager

    init(apiKeyManager: APIKeyManager = .shared) {
        self.apiKeyManager = apiKeyManager
    }

    func transcribe(
        audioData: Data,
        model: STTModel,
        language: String?
    ) async throws -> TranscriptionResult {
        guard let apiKey = apiKeyManager.getAPIKey(for: .openAI) else {
            throw STTError.invalidAPIKey
        }

        let format = AudioFormatConverter.normalizeFormat(audioData)
        let boundary = UUID().uuidString
        var body = Data()

        // Add file field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(format.fileExtension)\"\r\n")
        body.append("Content-Type: \(format.mimeType)\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        // Add model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model.rawValue)\r\n")

        // Add response_format field
        let responseFormat = model == .whisper1 ? "verbose_json" : "json"
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.append("\(responseFormat)\r\n")

        // Add include[] for logprobs (non-whisper models)
        if model != .whisper1 {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"include[]\"\r\n\r\n")
            body.append("logprobs\r\n")
        }

        // Add language if specified
        if let lang = language, lang != "auto" {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.append("\(lang)\r\n")
        }

        body.append("--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.networkError(URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw STTError.apiError("OpenAI API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        let json = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)

        let confidence: Double?
        if let logprobs = json.logprobs, !logprobs.isEmpty {
            let avgLogprob = logprobs.map { $0.logprob }.reduce(0, +) / Double(logprobs.count)
            confidence = exp(avgLogprob)
        } else if let segments = json.segments, !segments.isEmpty {
            let avgLogprob = segments.map { $0.avgLogprob }.reduce(0, +) / Double(segments.count)
            confidence = exp(avgLogprob)
        } else {
            confidence = nil
        }

        return TranscriptionResult(
            text: json.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence,
            languageCode: json.language
        )
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
    let language: String?
    let logprobs: [LogprobEntry]?
    let segments: [Segment]?

    struct LogprobEntry: Decodable {
        let logprob: Double
    }

    struct Segment: Decodable {
        let avgLogprob: Double

        enum CodingKeys: String, CodingKey {
            case avgLogprob = "avg_logprob"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
