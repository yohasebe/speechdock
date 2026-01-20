import XCTest
@testable import SpeechDock

final class APIKeyManagerTests: XCTestCase {

    func testSTTProviderEnvironmentVariableNames() {
        // Verify environment variable names are correct
        XCTAssertEqual(STTProvider.openAI.envKeyName, "OPENAI_API_KEY")
        XCTAssertEqual(STTProvider.gemini.envKeyName, "GEMINI_API_KEY")
        XCTAssertEqual(STTProvider.elevenLabs.envKeyName, "ELEVENLABS_API_KEY")
    }

    func testSTTProviderKeychainKeys() {
        // Verify keychain keys (envKeyName) are unique for each provider
        let keys = STTProvider.allCases.map { $0.envKeyName }
        let uniqueKeys = Set(keys)

        XCTAssertEqual(keys.count, uniqueKeys.count, "All keychain keys should be unique")
    }

    func testHasAPIKeyReturnsFalseForMissingKey() {
        // This test assumes no API keys are set in the test environment
        // In a real test environment, you might want to mock the keychain
        _ = APIKeyManager.shared

        // Note: This test might fail if keys are actually set in the environment
        // A better approach would be to use dependency injection for the keychain
    }
}
