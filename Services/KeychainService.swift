import Foundation
import Security

enum KeychainError: Error {
    case invalidData
    case itemNotFound
    case duplicateItem
    case unhandledError(status: OSStatus)
}

/// Thread-safe keychain service for storing sensitive data
final class KeychainService {
    private let service = "com.typetalk.apikeys"

    /// Lock for thread-safe keychain access
    private let lock = NSLock()

    func save(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Delete existing item first (using unlocked version to avoid deadlock)
        try? _deleteUnlocked(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    func retrieve(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }

        try _deleteUnlocked(key: key)
    }

    /// Internal delete without locking (called from within locked context)
    private func _deleteUnlocked(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}
