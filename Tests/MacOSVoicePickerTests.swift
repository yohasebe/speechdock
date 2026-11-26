import XCTest
@testable import SpeechDock

final class MacOSVoicePickerTests: XCTestCase {
    private let list = [
        "Samantha (English (US)) en_US    # Hello! My name is Samantha.",
        "Linh (Vietnamese (Vietnam)) vi_VN    # Xin chào! Tên tôi là Linh.",
        "Linh (Enhanced) (Vietnamese (Vietnam)) vi_VN    # Xin chào! Tên tôi là Linh.",
        "",
    ]

    func testPicksEnhancedVietnameseVoice() {
        XCTAssertEqual(MacOSTTS.installedVoice(for: "vi", in: list), "Linh (Enhanced)")
    }

    func testPicksPlainVoiceWhenOnlyOneInstalled() {
        XCTAssertEqual(MacOSTTS.installedVoice(for: "vi", in: Array(list.prefix(2))), "Linh")
    }

    func testNoVoiceForMissingLanguage() {
        XCTAssertNil(MacOSTTS.installedVoice(for: "th", in: list))
    }
}
