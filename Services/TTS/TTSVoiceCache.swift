import Foundation

/// Manages caching of TTS voices for fast startup
@MainActor
final class TTSVoiceCache {
    static let shared = TTSVoiceCache()

    private let defaults = UserDefaults.standard
    private let cacheKeyPrefix = "ttsVoiceCache_"
    private let cacheTimestampPrefix = "ttsVoiceCacheTime_"
    private let cacheVersionKey = "ttsVoiceCacheVersion"
    private let currentCacheVersion = 2  // Increment when cache format changes
    private let cacheExpirationInterval: TimeInterval = 24 * 60 * 60  // 24 hours

    private init() {
        // Clear cache if version changed (e.g., added quality property)
        migrateIfNeeded()
    }

    /// Clear all caches if version changed
    private func migrateIfNeeded() {
        let storedVersion = defaults.integer(forKey: cacheVersionKey)
        if storedVersion < currentCacheVersion {
            // Clear all provider caches
            for provider in TTSProvider.allCases {
                clearCache(for: provider)
            }
            defaults.set(currentCacheVersion, forKey: cacheVersionKey)
            #if DEBUG
            print("TTSVoiceCache: Migrated from version \(storedVersion) to \(currentCacheVersion)")
            #endif
        }
    }

    /// Get cached voices for a provider
    func getCachedVoices(for provider: TTSProvider) -> [TTSVoice]? {
        let key = cacheKeyPrefix + provider.rawValue

        guard let data = defaults.data(forKey: key),
              let cached = try? JSONDecoder().decode([CachedVoice].self, from: data) else {
            return nil
        }

        return cached.map {
            TTSVoice(
                id: $0.id,
                name: $0.name,
                language: $0.language,
                isDefault: $0.isDefault,
                quality: VoiceQuality(rawValue: $0.qualityRawValue) ?? .standard
            )
        }
    }

    /// Save voices to cache
    func cacheVoices(_ voices: [TTSVoice], for provider: TTSProvider) {
        let key = cacheKeyPrefix + provider.rawValue
        let timestampKey = cacheTimestampPrefix + provider.rawValue

        let cached = voices.map {
            CachedVoice(
                id: $0.id,
                name: $0.name,
                language: $0.language,
                isDefault: $0.isDefault,
                qualityRawValue: $0.quality.rawValue
            )
        }

        do {
            let data = try JSONEncoder().encode(cached)
            defaults.set(data, forKey: key)
            defaults.set(Date().timeIntervalSince1970, forKey: timestampKey)
        } catch {
            #if DEBUG
            print("TTSVoiceCache: Failed to cache voices for \(provider.rawValue): \(error)")
            #endif
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
    let qualityRawValue: Int

    // Support decoding old cache format without quality
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        language = try container.decode(String.self, forKey: .language)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        qualityRawValue = try container.decodeIfPresent(Int.self, forKey: .qualityRawValue) ?? 0
    }

    init(id: String, name: String, language: String, isDefault: Bool, qualityRawValue: Int) {
        self.id = id
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.qualityRawValue = qualityRawValue
    }
}
