import XCTest
@testable import SpeechDock

/// The xAI file transcription request body and response shape.
final class GrokSTTClientTests: XCTestCase {
    private func body(language: String?) -> String {
        let data = GrokSTTClient.multipartBody(
            audioData: Data("AUDIO".utf8),
            fileExtension: "mp3",
            mimeType: "audio/mpeg",
            language: language,
            boundary: "BOUNDARY"
        )
        return String(decoding: data, as: UTF8.self)
    }

    func testLanguagePrecedesFile() throws {
        let text = body(language: "ja")
        let language = try XCTUnwrap(text.range(of: "name=\"language\"\r\n\r\nja\r\n"))
        let file = try XCTUnwrap(text.range(of: "name=\"file\"; filename=\"audio.mp3\""))
        XCTAssertLessThan(language.lowerBound, file.lowerBound)
    }

    func testFileIsTheLastField() {
        XCTAssertTrue(body(language: "ja").hasSuffix("AUDIO\r\n--BOUNDARY--\r\n"))
    }

    func testAutoDetectSendsNoLanguage() {
        for language in [nil, "", "auto"] {
            XCTAssertFalse(body(language: language).contains("name=\"language\""))
        }
    }

    func testResponseIsDecoded() throws {
        let json = #"{"text": "Bonjour", "language": "fr", "duration": 1.5, "words": []}"#
        let response = try JSONDecoder().decode(GrokTranscriptionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.text, "Bonjour")
        XCTAssertEqual(response.language, "fr")
    }

    func testResponseWithoutLanguageIsAccepted() throws {
        let response = try JSONDecoder().decode(GrokTranscriptionResponse.self, from: Data(#"{"text": "Hello"}"#.utf8))
        XCTAssertNil(response.language)
    }

    func testGrokRejectsAIFFButAcceptsAAC() {
        XCTAssertFalse(AudioFileSupport.extensions(for: .grok).contains("aiff"))
        XCTAssertFalse(AudioFileSupport.extensions(for: .grok).contains("aif"))
        XCTAssertTrue(AudioFileSupport.extensions(for: .grok).contains("aac"))
        XCTAssertFalse(AudioFileSupport.extensions(for: .openAI).contains("aac"))
        XCTAssertTrue(AudioFileSupport.extensions(for: .gemini).contains("aiff"))
    }
}
