import Foundation

final class APIKeyManager {
    static let shared = APIKeyManager()

    private let keychainService = KeychainService()

    private init() {}

    func getAPIKey(for provider: STTProvider) -> String? {
        // 1. Check environment variable first
        if let envKey = ProcessInfo.processInfo.environment[provider.envKeyName],
           !envKey.isEmpty {
            return envKey
        }

        // 2. Fallback to Keychain
        return keychainService.retrieve(key: provider.envKeyName)
    }

    func setAPIKey(_ key: String, for provider: STTProvider) throws {
        try keychainService.save(key: provider.envKeyName, value: key)
    }

    func deleteAPIKey(for provider: STTProvider) throws {
        try keychainService.delete(key: provider.envKeyName)
    }

    func hasAPIKey(for provider: STTProvider) -> Bool {
        return getAPIKey(for: provider) != nil
    }

    func apiKeySource(for provider: STTProvider) -> APIKeySource {
        if let envKey = ProcessInfo.processInfo.environment[provider.envKeyName],
           !envKey.isEmpty {
            return .environment
        }
        if keychainService.retrieve(key: provider.envKeyName) != nil {
            return .keychain
        }
        return .none
    }
}

enum APIKeySource {
    case environment
    case keychain
    case none
}
