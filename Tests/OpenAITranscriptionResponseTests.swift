import XCTest
@testable import SpeechDock

/// The gpt-transcribe response shape: `text` and a `languages` list.
final class OpenAITranscriptionResponseTests: XCTestCase {
    private func decode(_ json: String) throws -> OpenAITranscriptionResponse {
        try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: Data(json.utf8))
    }

    func testDetectedLanguageIsRead() throws {
        let response = try decode(#"{"text": "Bonjour", "languages": [{"code": "fr"}]}"#)
        XCTAssertEqual(response.text, "Bonjour")
        XCTAssertEqual(response.languages?.first?.code, "fr")
    }

    func testNoReliableLanguageIsEmpty() throws {
        let response = try decode(#"{"text": "Hello", "languages": []}"#)
        XCTAssertNil(response.languages?.first)
    }

    func testMissingLanguagesIsAccepted() throws {
        XCTAssertEqual(try decode(#"{"text": "Hello"}"#).text, "Hello")
    }
}
