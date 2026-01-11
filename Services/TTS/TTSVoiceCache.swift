import Foundation

/// Manages caching of TTS voices for fast startup
@MainActor
final class TTSVoiceCache {
    static let shared = TTSVoiceCache()

    private let defaults = UserDefaults.standard
    private let cacheKeyPrefix = "ttsVoiceCache_"
    private let cacheTimestampPrefix = "ttsVoiceCacheTime_"
    private let cacheExpirationInterval: TimeInterval = 24 * 60 * 60  // 24 hours

    private init() {}

    /// Get cached voices for a provider
    func getCachedVoices(for provider: TTSProvider) -> [TTSVoice]? {
        let key = cacheKeyPrefix + provider.rawValue

        guard let data = defaults.data(forKey: key),
              let cached = try? JSONDecoder().decode([CachedVoice].self, from: data) else {
            return nil
        }

        return cached.map { TTSVoice(id: $0.id, name: $0.name, language: $0.language, isDefault: $0.isDefault) }
    }

    /// Save voices to cache
    func cacheVoices(_ voices: [TTSVoice], for provider: TTSProvider) {
        let key = cacheKeyPrefix + provider.rawValue
        let timestampKey = cacheTimestampPrefix + provider.rawValue

        let cached = voices.map { CachedVoice(id: $0.id, name: $0.name, language: $0.language, isDefault: $0.isDefault) }

        if let data = try? JSONEncoder().encode(cached) {
            defaults.set(data, forKey: key)
            defaults.set(Date().timeIntervalSince1970, forKey: timestampKey)
        }
    }

    /// Check if cache is expired
    func isCacheExpired(for provider: TTSProvider) -> Bool {
        let timestampKey = cacheTimestampPrefix + provider.rawValue

        guard let timestamp = defaults.object(forKey: timestampKey) as? TimeInterval else {
            return true  // No cache timestamp means expired
        }

        let cacheDate = Date(timeIntervalSince1970: timestamp)
        return Date().timeIntervalSince(cacheDate) > cacheExpirationInterval
    }

    /// Clear cache for a provider
    func clearCache(for provider: TTSProvider) {
        let key = cacheKeyPrefix + provider.rawValue
        let timestampKey = cacheTimestampPrefix + provider.rawValue
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: timestampKey)
    }
}

/// Codable wrapper for TTSVoice
private struct CachedVoice: Codable {
    let id: String
    let name: String
    let language: String
    let isDefault: Bool
}
