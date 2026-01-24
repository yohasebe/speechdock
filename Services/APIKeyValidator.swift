import Foundation

enum ValidationResult {
    case valid
    case invalid(String)
    case networkError(String)
}

struct APIKeyValidator {
    static func validate(key: String, for provider: STTProvider) async -> ValidationResult {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return .invalid("Key is empty")
        }

        switch provider {
        case .openAI:
            return await validateOpenAI(key: trimmedKey)
        case .gemini:
            return await validateGemini(key: trimmedKey)
        case .elevenLabs:
            return await validateElevenLabs(key: trimmedKey)
        case .grok:
            return await validateGrok(key: trimmedKey)
        }
    }

    private static func validateOpenAI(key: String) async -> ValidationResult {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            return .networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        return await performRequest(request)
    }

    private static func validateGemini(key: String) async -> ValidationResult {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)") else {
            return .networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        return await performRequest(request)
    }

    private static func validateElevenLabs(key: String) async -> ValidationResult {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user") else {
            return .networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10
        return await performRequest(request)
    }

    private static func validateGrok(key: String) async -> ValidationResult {
        guard let url = URL(string: "https://api.x.ai/v1/models") else {
            return .networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        return await performRequest(request)
    }

    private static func performRequest(_ request: URLRequest) async -> ValidationResult {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError("Invalid response")
            }
            switch httpResponse.statusCode {
            case 200:
                return .valid
            case 401, 403:
                return .invalid("Invalid API key")
            default:
                return .networkError("HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }
}
