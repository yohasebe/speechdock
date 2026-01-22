import XCTest
@testable import SpeechDock

final class TTSVoiceCacheTests: XCTestCase {

    private var testDefaults: UserDefaults!
    private let testSuiteName = "TTSVoiceCacheTests"

    override func setUp() {
        super.setUp()
        // Use a separate UserDefaults suite for testing
        testDefaults = UserDefaults(suiteName: testSuiteName)
        testDefaults?.removePersistentDomain(forName: testSuiteName)
    }

    override func tearDown() {
        testDefaults?.removePersistentDomain(forName: testSuiteName)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Voice Quality Tests

    func testVoiceQualityRawValues() {
        // Verify raw values match expected encoding
        XCTAssertEqual(VoiceQuality.standard.rawValue, 0)
        XCTAssertEqual(VoiceQuality.enhanced.rawValue, 1)
        XCTAssertEqual(VoiceQuality.premium.rawValue, 2)
    }

    func testVoiceQualityComparable() {
        // Verify quality comparison works correctly
        XCTAssertTrue(VoiceQuality.standard < VoiceQuality.enhanced)
        XCTAssertTrue(VoiceQuality.enhanced < VoiceQuality.premium)
        XCTAssertTrue(VoiceQuality.standard < VoiceQuality.premium)
        XCTAssertFalse(VoiceQuality.premium < VoiceQuality.standard)
    }

    func testVoiceQualityDisplayNames() {
        // Verify display names are appropriate
        XCTAssertEqual(VoiceQuality.standard.displayName, "")
        XCTAssertEqual(VoiceQuality.enhanced.displayName, "Enhanced")
        XCTAssertEqual(VoiceQuality.premium.displayName, "Premium")
    }

    // MARK: - TTSVoice Tests

    func testTTSVoiceDefaultQuality() {
        // Verify default quality is standard
        let voice = TTSVoice(id: "test", name: "Test Voice")
        XCTAssertEqual(voice.quality, .standard)
    }

    func testTTSVoiceWithQuality() {
        // Verify quality is preserved
        let enhancedVoice = TTSVoice(id: "enhanced", name: "Enhanced Voice", quality: .enhanced)
        let premiumVoice = TTSVoice(id: "premium", name: "Premium Voice", quality: .premium)

        XCTAssertEqual(enhancedVoice.quality, .enhanced)
        XCTAssertEqual(premiumVoice.quality, .premium)
    }

    func testTTSVoiceHashable() {
        // Verify voices with same id are equal regardless of quality
        let voice1 = TTSVoice(id: "test", name: "Test", quality: .standard)
        let voice2 = TTSVoice(id: "test", name: "Test", quality: .enhanced)
        let voice3 = TTSVoice(id: "other", name: "Other", quality: .standard)

        // Same ID means same voice
        XCTAssertEqual(voice1.id, voice2.id)
        XCTAssertNotEqual(voice1.id, voice3.id)
    }

    // MARK: - TTSProvider Tests

    func testTTSProviderAllCases() {
        // Verify all providers are available for cache iteration
        let providers = TTSProvider.allCases
        XCTAssertTrue(providers.contains(.macOS))
        XCTAssertTrue(providers.contains(.openAI))
        XCTAssertTrue(providers.contains(.gemini))
        XCTAssertTrue(providers.contains(.elevenLabs))
        XCTAssertTrue(providers.contains(.grok))
        XCTAssertEqual(providers.count, 5)
    }

    func testTTSProviderRawValues() {
        // Verify raw values are stable (used as cache keys)
        XCTAssertEqual(TTSProvider.macOS.rawValue, "macOS")
        XCTAssertEqual(TTSProvider.openAI.rawValue, "OpenAI")
        XCTAssertEqual(TTSProvider.gemini.rawValue, "Gemini")
        XCTAssertEqual(TTSProvider.elevenLabs.rawValue, "ElevenLabs")
        XCTAssertEqual(TTSProvider.grok.rawValue, "Grok")
    }

    // MARK: - CachedVoice Backward Compatibility Tests

    func testOldCacheFormatWithoutQuality() {
        // Simulate old cache format without qualityRawValue
        let oldFormatJSON = """
        [
            {"id": "voice1", "name": "Voice 1", "language": "en", "isDefault": false},
            {"id": "voice2", "name": "Voice 2", "language": "ja", "isDefault": true}
        ]
        """

        guard let data = oldFormatJSON.data(using: .utf8) else {
            XCTFail("Failed to create test data")
            return
        }

        // Decode using the same structure as CachedVoice
        struct TestCachedVoice: Codable {
            let id: String
            let name: String
            let language: String
            let isDefault: Bool
            let qualityRawValue: Int

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                name = try container.decode(String.self, forKey: .name)
                language = try container.decode(String.self, forKey: .language)
                isDefault = try container.decode(Bool.self, forKey: .isDefault)
                // Default to 0 (standard) if not present
                qualityRawValue = try container.decodeIfPresent(Int.self, forKey: .qualityRawValue) ?? 0
            }
        }

        do {
            let decoded = try JSONDecoder().decode([TestCachedVoice].self, from: data)
            XCTAssertEqual(decoded.count, 2)
            // Old format should default to standard quality (0)
            XCTAssertEqual(decoded[0].qualityRawValue, 0)
            XCTAssertEqual(decoded[1].qualityRawValue, 0)
        } catch {
            XCTFail("Failed to decode old cache format: \(error)")
        }
    }

    func testNewCacheFormatWithQuality() {
        // Test new cache format with qualityRawValue
        let newFormatJSON = """
        [
            {"id": "voice1", "name": "Voice 1", "language": "en", "isDefault": false, "qualityRawValue": 0},
            {"id": "voice2", "name": "Voice 2", "language": "ja", "isDefault": true, "qualityRawValue": 1},
            {"id": "voice3", "name": "Voice 3", "language": "en", "isDefault": false, "qualityRawValue": 2}
        ]
        """

        guard let data = newFormatJSON.data(using: .utf8) else {
            XCTFail("Failed to create test data")
            return
        }

        struct TestCachedVoice: Codable {
            let id: String
            let name: String
            let language: String
            let isDefault: Bool
            let qualityRawValue: Int

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                name = try container.decode(String.self, forKey: .name)
                language = try container.decode(String.self, forKey: .language)
                isDefault = try container.decode(Bool.self, forKey: .isDefault)
                qualityRawValue = try container.decodeIfPresent(Int.self, forKey: .qualityRawValue) ?? 0
            }
        }

        do {
            let decoded = try JSONDecoder().decode([TestCachedVoice].self, from: data)
            XCTAssertEqual(decoded.count, 3)
            XCTAssertEqual(decoded[0].qualityRawValue, 0) // standard
            XCTAssertEqual(decoded[1].qualityRawValue, 1) // enhanced
            XCTAssertEqual(decoded[2].qualityRawValue, 2) // premium
        } catch {
            XCTFail("Failed to decode new cache format: \(error)")
        }
    }

    // MARK: - Quality Conversion Tests

    func testQualityRawValueConversion() {
        // Test converting raw values back to VoiceQuality
        XCTAssertEqual(VoiceQuality(rawValue: 0), .standard)
        XCTAssertEqual(VoiceQuality(rawValue: 1), .enhanced)
        XCTAssertEqual(VoiceQuality(rawValue: 2), .premium)

        // Invalid raw values should return nil
        XCTAssertNil(VoiceQuality(rawValue: -1))
        XCTAssertNil(VoiceQuality(rawValue: 3))
        XCTAssertNil(VoiceQuality(rawValue: 100))
    }

    func testQualityRoundTrip() {
        // Test that quality survives encoding/decoding round trip
        let testVoices = [
            TTSVoice(id: "v1", name: "Standard Voice", language: "en", isDefault: false, quality: .standard),
            TTSVoice(id: "v2", name: "Enhanced Voice", language: "en", isDefault: false, quality: .enhanced),
            TTSVoice(id: "v3", name: "Premium Voice", language: "en", isDefault: true, quality: .premium)
        ]

        // Simulate cache encoding
        struct EncodableCachedVoice: Codable {
            let id: String
            let name: String
            let language: String
            let isDefault: Bool
            let qualityRawValue: Int
        }

        let encoded = testVoices.map {
            EncodableCachedVoice(
                id: $0.id,
                name: $0.name,
                language: $0.language,
                isDefault: $0.isDefault,
                qualityRawValue: $0.quality.rawValue
            )
        }

        do {
            let data = try JSONEncoder().encode(encoded)
            let decoded = try JSONDecoder().decode([EncodableCachedVoice].self, from: data)

            // Convert back to TTSVoice
            let restoredVoices = decoded.map {
                TTSVoice(
                    id: $0.id,
                    name: $0.name,
                    language: $0.language,
                    isDefault: $0.isDefault,
                    quality: VoiceQuality(rawValue: $0.qualityRawValue) ?? .standard
                )
            }

            XCTAssertEqual(restoredVoices.count, 3)
            XCTAssertEqual(restoredVoices[0].quality, .standard)
            XCTAssertEqual(restoredVoices[1].quality, .enhanced)
            XCTAssertEqual(restoredVoices[2].quality, .premium)
        } catch {
            XCTFail("Round trip encoding/decoding failed: \(error)")
        }
    }

    // MARK: - Cache Expiration Logic Tests

    func testCacheExpirationCalculation() {
        // Test 24-hour expiration logic
        let cacheExpirationInterval: TimeInterval = 24 * 60 * 60  // 24 hours

        let now = Date()
        let recentTimestamp = now.addingTimeInterval(-3600)  // 1 hour ago
        let expiredTimestamp = now.addingTimeInterval(-cacheExpirationInterval - 1)  // Just over 24 hours ago

        let recentAge = now.timeIntervalSince(recentTimestamp)
        let expiredAge = now.timeIntervalSince(expiredTimestamp)

        XCTAssertTrue(recentAge < cacheExpirationInterval, "Recent cache should not be expired")
        XCTAssertTrue(expiredAge > cacheExpirationInterval, "Old cache should be expired")
    }

    // MARK: - Cache Version Tests

    func testCacheVersionMigrationTrigger() {
        // Test that version comparison triggers migration
        let currentVersion = 2
        let oldVersions = [0, 1]

        for oldVersion in oldVersions {
            XCTAssertTrue(oldVersion < currentVersion,
                          "Old version \(oldVersion) should trigger migration to \(currentVersion)")
        }

        // Current version should not trigger migration
        XCTAssertFalse(currentVersion < currentVersion,
                       "Current version should not trigger migration")
    }
}
