import XCTest
@testable import SpeechDock

final class MacOSVoicePickerTests: XCTestCase {
    private let list = [
        "Samantha (English (US)) en_US    # sample",
        "Linh (Vietnamese (Vietnam)) vi_VN    # sample",
        "Linh (Enhanced) (Vietnamese (Vietnam)) vi_VN    # sample",
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
