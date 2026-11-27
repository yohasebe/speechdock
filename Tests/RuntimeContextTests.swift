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
        let key = "panelTextFontSize"
        let before = UserDefaults.standard.object(forKey: key) as? Double
        let app = AppState.shared
        let original = app.panelTextFontSize
        app.panelTextFontSize = (before ?? original) == AppState.maxPanelTextFontSize
            ? AppState.minPanelTextFontSize : AppState.maxPanelTextFontSize
        defer { app.panelTextFontSize = original }
        try await Task.sleep(for: .milliseconds(500))  // past the save debounce
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Double, before)
    }
}
