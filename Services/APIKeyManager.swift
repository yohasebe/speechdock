import Foundation

final class APIKeyManager {
    static let shared = APIKeyManager()

    private let keychainService = KeychainService()

    /// Test mode flag - when true, all external API keys return nil
    /// Set via environment variable: SPEECHDOCK_TEST_NO_API_KEYS=1
    private var isTestModeNoAPIKeys: Bool {
        ProcessInfo.processInfo.environment["SPEECHDOCK_TEST_NO_API_KEYS"] == "1"
    }

    private init() {}

    func getAPIKey(for provider: STTProvider) -> String? {
        // Test mode: return nil for all external API keys
        if isTestModeNoAPIKeys {
            return nil
        }

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
        // Test mode: return nil for all external API keys
        if isTestModeNoAPIKeys {
            return nil
        }

        // 1. Check process environment variable first
        if let envKey = ProcessInfo.processInfo.environment[envKeyName],
           !envKey.isEmpty {
            return envKey
        }

        // 2. Use Keychain
        return keychainService.retrieve(key: envKeyName)
    }

    func apiKeySource(for provider: STTProvider) -> APIKeySource {
        // Test mode: always return none
        if isTestModeNoAPIKeys {
            return .none
        }

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
