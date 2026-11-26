import XCTest
@testable import SpeechDock

final class LiveOCRLocalizationTests: XCTestCase {

    func testAllSixBundledLocalesTranslateLiveOCRStrings() throws {
        let resources = try XCTUnwrap(Bundle(for: AppDelegate.self).resourceURL)
        let keys = [
            "Live Subtitles", "Read Subtitles from Screen…", "Stop Live OCR", "Read Aloud", "Show Subtitle Text",
            "Translate First", "Speak in", "Gemini Live interpreter (translates as it speaks)",
            "Same as Text-to-Speech (%@)", "Toggle Live OCR Subtitles", "Live OCR",
            "Screen Recording is needed to read subtitles", "Capture interval"
        ]
        for locale in ["en", "ja", "de", "fr", "ko", "zh-Hans"] {
            let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent(locale + ".lproj")))
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "__missing__", table: nil), "__missing__",
                                  "Missing \(locale): \(key)")
            }
        }
    }
}
