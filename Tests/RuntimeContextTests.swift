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
}
