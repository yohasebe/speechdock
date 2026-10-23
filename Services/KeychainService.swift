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
    /// The development build keeps its own items, so it never reads (and
    /// prompts for) the keys the released app saved.
    #if DEBUG
    private let service = "com.speechdock.apikeys.dev"
    #else
    private let service = "com.speechdock.apikeys"
    #endif

    /// Lock for thread-safe keychain access
    private let lock = NSLock()

    func save(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        // Add first; fall back to update if the item already exists
        // (avoids the non-atomic delete-then-add losing the existing key on failure)
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ]
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
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

        // Only "not found" means absence; other errors (e.g. keychain locked)
        // are logged so they can be distinguished from a missing item
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            dprint("KeychainService: retrieve failed for key '\(key)' (status \(status))")
            return nil
        }

        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            dprint("KeychainService: stored data for key '\(key)' is not valid UTF-8")
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
