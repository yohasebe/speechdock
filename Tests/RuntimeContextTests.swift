import XCTest
@testable import SpeechDock

final class RuntimeContextTests: XCTestCase {
    func testUnitTestHostIsRecognized() {
        XCTAssertTrue(RuntimeContext.isUnitTestHost)
    }

    func testUnitTestHostReadsNoKeys() {
        let keys = APIKeyManager(environment: { ["OPENAI_API_KEY": "not-a-real-key"] })
        XCTAssertNil(keys.keyOrigin(for: .openAI))
        XCTAssertNil(keys.storedKeychainValue(for: .openAI))
    }

    @MainActor
    func testSharedStateInTheTestHostDoesNotSavePreferences() async throws {
        let key = "selectedTTSProvider"
        let before = UserDefaults.standard.string(forKey: key)
        let app = AppState.shared
        let original = app.selectedTTSProvider
        app.selectedTTSProvider = original == .macOS ? .gemini : .macOS
        defer { app.selectedTTSProvider = original }
        try await Task.sleep(for: .milliseconds(500))  // past the save debounce
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), before)
    }
}
