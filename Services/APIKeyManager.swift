import Foundation

final class APIKeyManager {
    static let shared = APIKeyManager()

    private let keychainService = KeychainService()
    private var envFileCache: [String: String]?

    private init() {
        loadEnvFile()
    }

    /// Load environment variables from ~/.typetalk.env file
    private func loadEnvFile() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let envFilePath = homeDir.appendingPathComponent(".typetalk.env")

        print("APIKeyManager: Looking for config file at \(envFilePath.path)")

        guard FileManager.default.fileExists(atPath: envFilePath.path) else {
            print("APIKeyManager: Config file not found")
            return
        }

        print("APIKeyManager: Config file found, loading...")

        do {
            let content = try String(contentsOf: envFilePath, encoding: .utf8)
            var envVars: [String: String] = [:]

            for line in content.components(separatedBy: .newlines) {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)

                // Skip empty lines and comments
                if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                    continue
                }

                // Parse KEY=VALUE format
                if let equalIndex = trimmedLine.firstIndex(of: "=") {
                    let key = String(trimmedLine[..<equalIndex]).trimmingCharacters(in: .whitespaces)
                    var value = String(trimmedLine[trimmedLine.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)

                    // Remove surrounding quotes if present
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                       (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }

                    if !key.isEmpty && !value.isEmpty {
                        envVars[key] = value
                    }
                }
            }

            envFileCache = envVars
            print("APIKeyManager: Loaded \(envVars.count) keys from config file: \(envVars.keys.joined(separator: ", "))")
        } catch {
            print("APIKeyManager: Failed to load config file: \(error)")
        }
    }

    func getAPIKey(for provider: STTProvider) -> String? {
        // 1. Check process environment variable first (for terminal launch)
        if let envKey = ProcessInfo.processInfo.environment[provider.envKeyName],
           !envKey.isEmpty {
            return envKey
        }

        // 2. Check ~/.env file (for Finder launch)
        if let envKey = envFileCache?[provider.envKeyName],
           !envKey.isEmpty {
            return envKey
        }

        // 3. Fallback to Keychain
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
        // Check process environment
        if let envKey = ProcessInfo.processInfo.environment[provider.envKeyName],
           !envKey.isEmpty {
            return .environment
        }
        // Check ~/.env file
        if let envKey = envFileCache?[provider.envKeyName],
           !envKey.isEmpty {
            return .envFile
        }
        // Check Keychain
        if keychainService.retrieve(key: provider.envKeyName) != nil {
            return .keychain
        }
        return .none
    }
}

enum APIKeySource {
    case environment  // From shell environment (terminal launch)
    case envFile      // From ~/.env file (Finder launch)
    case keychain     // From macOS Keychain
    case none
}
