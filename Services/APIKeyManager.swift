import Foundation
import Observation

/// Keychain access used by APIKeyManager. Replaced in tests.
protocol APIKeyStore {
    func retrieve(key: String) -> String?
    func save(key: String, value: String) throws
    func delete(key: String) throws
}

extension KeychainService: APIKeyStore {}

/// Bumped when 1Password reference results change, so views that check key
/// availability are drawn again.
@MainActor @Observable
final class APIKeyChangeSignal {
    static let shared = APIKeyChangeSignal()
    var revision = 0
}

/// Whether a provider's key can be used.
enum APIKeyStatus: Equatable {
    case notSet
    case ready
    /// A 1Password reference that has not been read yet. Counts as available:
    /// using it waits for the read.
    case pending
    case failed(SecretReferenceFailure)
}

final class APIKeyManager {
    static let shared = APIKeyManager()

    /// Canonical key names and the older names still accepted, in reading order.
    static let keyNameAliases: [String: [String]] = [
        "XAI_API_KEY": ["XAI_API_KEY", "GROK_API_KEY"]
    ]

    /// The canonical name for `name` (an older name maps to the current one).
    static func canonicalName(_ name: String) -> String {
        keyNameAliases.first { $0.value.contains(name) }?.key ?? name
    }

    /// Names to look up for `name`, the canonical one first.
    static func candidateNames(_ name: String) -> [String] {
        let canonical = canonicalName(name)
        return keyNameAliases[canonical] ?? [canonical]
    }

    private let keychain: APIKeyStore
    private let environment: () -> [String: String]
    private let testModeNoAPIKeys: Bool
    let referenceResolver: SecretReferenceResolver

    init(keychain: APIKeyStore = KeychainService(),
         environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         // The unit-test host never reads real keys: the keychain would ask the user.
         testModeNoAPIKeys: Bool = ProcessInfo.processInfo.environment["SPEECHDOCK_TEST_NO_API_KEYS"] == "1"
            || RuntimeContext.isUnitTestHost,
         referenceResolver: SecretReferenceResolver? = nil) {
        self.keychain = keychain
        self.environment = environment
        self.testModeNoAPIKeys = testModeNoAPIKeys
        self.referenceResolver = referenceResolver ?? SecretReferenceResolver(onChange: {
            Task { @MainActor in APIKeyChangeSignal.shared.revision += 1 }
        })
    }

    // MARK: - Lookup

    /// Where a key was found, without reading any 1Password reference.
    struct KeyOrigin: Equatable {
        let source: APIKeySource
        /// The name it was found under (may be an older name).
        let name: String
        /// The stored text: the key itself, or a 1Password reference.
        let storedValue: String

        var isReference: Bool { SecretReference.isReference(storedValue) }
        var isLegacyName: Bool { APIKeyManager.canonicalName(name) != name }
    }

    /// Environment variables first, then the keychain; within each, the
    /// canonical name before older ones.
    func keyOrigin(for name: String) -> KeyOrigin? {
        guard !testModeNoAPIKeys else { return nil }
        let names = Self.candidateNames(name)
        let env = environment()
        for candidate in names {
            if let value = env[candidate], !value.isEmpty {
                return KeyOrigin(source: .environment, name: candidate, storedValue: value)
            }
        }
        for candidate in names {
            if let value = keychain.retrieve(key: candidate), !value.isEmpty {
                return KeyOrigin(source: .keychain, name: candidate, storedValue: value)
            }
        }
        return nil
    }

    func keyOrigin(for provider: STTProvider) -> KeyOrigin? {
        keyOrigin(for: provider.envKeyName)
    }

    // MARK: - Synchronous reads (never wait, never start op)

    /// The key for immediate use, or nil. A 1Password reference gives its
    /// value only once it has been read; the reference text is never returned.
    func getAPIKey(for name: String) -> String? {
        guard let origin = keyOrigin(for: name) else { return nil }
        if origin.isReference {
            return referenceResolver.cachedValue(for: origin.storedValue)
        }
        return origin.storedValue
    }

    func getAPIKey(for provider: STTProvider) -> String? {
        getAPIKey(for: provider.envKeyName)
    }

    func keyStatus(for name: String) -> APIKeyStatus {
        trackChanges()
        guard let origin = keyOrigin(for: name) else { return .notSet }
        guard origin.isReference else { return .ready }
        switch referenceResolver.state(for: origin.storedValue) {
        case .resolved?: return .ready
        case .failed(let failure)?: return .failed(failure)
        case nil: return .pending
        }
    }

    func keyStatus(for provider: STTProvider) -> APIKeyStatus {
        keyStatus(for: provider.envKeyName)
    }

    /// For enabling choices in the UI: a key is set and has not failed.
    func hasAPIKey(for name: String) -> Bool {
        switch keyStatus(for: name) {
        case .ready, .pending: return true
        case .notSet, .failed: return false
        }
    }

    func hasAPIKey(for provider: STTProvider) -> Bool {
        hasAPIKey(for: provider.envKeyName)
    }

    func apiKeySource(for provider: STTProvider) -> APIKeySource {
        keyOrigin(for: provider)?.source ?? .none
    }

    /// The keychain's stored text for the canonical name or an older one
    /// (the key or a reference), for the Settings field.
    func storedKeychainValue(for provider: STTProvider) -> String? {
        guard !testModeNoAPIKeys else { return nil }
        for candidate in Self.candidateNames(provider.envKeyName) {
            if let value = keychain.retrieve(key: candidate), !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Reads for use (may wait for 1Password)

    /// The key to send to the provider. A 1Password reference is read first
    /// (every reference the app knows, with one `op inject`), which can wait
    /// for an approval prompt. Nil when unset or unreadable;
    /// `unavailableReason(for:)` tells why.
    func apiKey(for name: String) async -> String? {
        guard let origin = keyOrigin(for: name) else { return nil }
        guard origin.isReference else { return origin.storedValue }
        switch await referenceResolver.value(for: origin.storedValue, batch: allReferences()) {
        case .success(let value): return value
        case .failure: return nil
        }
    }

    func apiKey(for provider: STTProvider) async -> String? {
        await apiKey(for: provider.envKeyName)
    }

    /// A message for a key that could not be used. Names the provider and,
    /// for a reference, the reason code only, never the reference text.
    func unavailableReason(for name: String) -> String {
        let providerName = Self.providerDisplayName(for: name)
        if case .failed(let failure) = keyStatus(for: name) {
            return String(format: NSLocalizedString("%@ API key: %@", comment: "API key unavailable: provider, reason"),
                          providerName, failure.localizedDescription)
        }
        return String(format: NSLocalizedString("%@ API key not found", comment: "API key unavailable: provider"),
                      providerName)
    }

    func unavailableReason(for provider: STTProvider) -> String {
        unavailableReason(for: provider.envKeyName)
    }

    /// Reads every reference not read yet (Settings opened).
    func prepareReferences() async {
        let references = allReferences()
        guard !references.isEmpty else { return }
        await referenceResolver.prepare(references)
    }

    /// Reads the provider's reference again, including after a cancelled approval.
    func reloadReference(for provider: STTProvider) async {
        guard let origin = keyOrigin(for: provider), origin.isReference else { return }
        referenceResolver.forget(origin.storedValue)
        _ = await referenceResolver.value(for: origin.storedValue, batch: allReferences(), force: true)
    }

    /// Reads one reference with `op read`, for checking it before it is saved.
    func readReference(_ reference: String) async -> Result<String, SecretReferenceFailure> {
        await referenceResolver.readSingle(reference)
    }

    /// The provider rejected the key (HTTP 401/403). A key read from a
    /// 1Password reference is read again on the next use, once.
    func providerRejectedKey(for name: String) {
        guard let origin = keyOrigin(for: name), origin.isReference else { return }
        if referenceResolver.providerRejected(origin.storedValue) {
            dprint("APIKeyManager: \(Self.canonicalName(name)) was rejected; its 1Password reference will be read again")
        }
    }

    func providerRejectedKey(for provider: STTProvider) {
        providerRejectedKey(for: provider.envKeyName)
    }

    /// Called with the HTTP status of every provider response; 401 and 403
    /// mean the key was rejected. `providerName` is the name the request
    /// helpers use ("OpenAI", "Grok TTS", ...).
    func noteResponse(statusCode: Int, providerName: String) {
        guard statusCode == 401 || statusCode == 403 else { return }
        let first = providerName.split(separator: " ").first.map(String.init) ?? providerName
        guard let provider = STTProvider(rawValue: first) else { return }
        providerRejectedKey(for: provider)
    }

    /// A WebSocket that failed: its handshake response tells whether the key was rejected.
    func noteHandshake(of task: URLSessionTask, provider: STTProvider) {
        guard let status = (task.response as? HTTPURLResponse)?.statusCode else { return }
        noteResponse(statusCode: status, providerName: provider.rawValue)
    }

    /// Every 1Password reference among the known key names (environment and keychain).
    private func allReferences() -> [String] {
        guard !testModeNoAPIKeys else { return [] }
        let env = environment()
        var references: [String] = []
        for provider in STTProvider.allCases {
            for candidate in Self.candidateNames(provider.envKeyName) {
                for value in [env[candidate], keychain.retrieve(key: candidate)] {
                    if let value, SecretReference.isReference(value) { references.append(value) }
                }
            }
        }
        return references
    }

    // MARK: - Writing

    /// Saves under the canonical name. Once that succeeds, items under older
    /// names are removed, so a replaced key does not linger behind the new one.
    /// Nothing is moved on its own: this runs only when the user saves.
    func setAPIKey(_ key: String, for provider: STTProvider) throws {
        let canonical = Self.canonicalName(provider.envKeyName)
        try keychain.save(key: canonical, value: key)
        for legacy in Self.candidateNames(canonical) where legacy != canonical {
            try? keychain.delete(key: legacy)
        }
    }

    /// Removes the key under every accepted name.
    func deleteAPIKey(for provider: STTProvider) throws {
        for candidate in Self.candidateNames(provider.envKeyName) {
            try keychain.delete(key: candidate)
        }
    }

    // MARK: - Helpers

    static func providerDisplayName(for name: String) -> String {
        let canonical = canonicalName(name)
        return STTProvider.allCases.first { canonicalName($0.envKeyName) == canonical }?.rawValue ?? canonical
    }

    /// Reading the signal inside a view's body makes the view depend on it.
    private func trackChanges() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { _ = APIKeyChangeSignal.shared.revision }
    }
}

enum APIKeySource {
    case environment  // From shell environment (development/terminal launch)
    case keychain     // From macOS Keychain (recommended)
    case none
}
