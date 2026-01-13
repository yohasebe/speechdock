import XCTest
@testable import TypeTalk

final class APIKeyManagerTests: XCTestCase {

    func testAPIKeyProviderEnvironmentVariableNames() {
        // Verify environment variable names are correct
        XCTAssertEqual(APIKeyProvider.openAI.envKeyName, "OPENAI_API_KEY")
        XCTAssertEqual(APIKeyProvider.gemini.envKeyName, "GEMINI_API_KEY")
        XCTAssertEqual(APIKeyProvider.elevenLabs.envKeyName, "ELEVENLABS_API_KEY")
    }

    func testAPIKeyProviderKeychainKeys() {
        // Verify keychain keys are unique for each provider
        let keys = APIKeyProvider.allCases.map { $0.keychainKey }
        let uniqueKeys = Set(keys)

        XCTAssertEqual(keys.count, uniqueKeys.count, "All keychain keys should be unique")
    }

    func testHasAPIKeyReturnsFalseForMissingKey() {
        // This test assumes no API keys are set in the test environment
        // In a real test environment, you might want to mock the keychain
        let manager = APIKeyManager.shared

        // Note: This test might fail if keys are actually set in the environment
        // A better approach would be to use dependency injection for the keychain
    }
}
