import Foundation

final class APIKeyManager {
    static let shared = APIKeyManager()

    private let keychainService = KeychainService()

    private init() {}

    func getAPIKey(for provider: STTProvider) -> String? {
        // 1. Check process environment variable first (for development/terminal launch)
        if let envKey = ProcessInfo.processInfo.environment[provider.envKeyName],
           !envKey.isEmpty {
            return envKey
        }

        // 2. Use Keychain (secure storage)
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

    /// Get API key by environment variable name directly
    /// Used by services that need to access keys by string name (e.g., Translation)
    func getAPIKey(for envKeyName: String) -> String? {
        // 1. Check process environment variable first
        if let envKey = ProcessInfo.processInfo.environment[envKeyName],
           !envKey.isEmpty {
            return envKey
        }

        // 2. Use Keychain
        return keychainService.retrieve(key: envKeyName)
    }

    func apiKeySource(for provider: STTProvider) -> APIKeySource {
        // Check process environment
        if let envKey = ProcessInfo.processInfo.environment[provider.envKeyName],
           !envKey.isEmpty {
            return .environment
        }
        // Check Keychain
        if keychainService.retrieve(key: provider.envKeyName) != nil {
            return .keychain
        }
        return .none
    }
}

enum APIKeySource {
    case environment  // From shell environment (development/terminal launch)
    case keychain     // From macOS Keychain (recommended)
    case none
}
