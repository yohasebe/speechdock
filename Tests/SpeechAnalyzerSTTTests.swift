import XCTest
@testable import SpeechDock

// SpeechAnalyzerSTT is only available with Swift 6.1+ compiler (macOS 26 SDK)
#if compiler(>=6.1)

/// Tests for SpeechAnalyzerSTT
/// Note: Full functionality tests require macOS 26+ and microphone access
@available(macOS 26, *)
@MainActor
final class SpeechAnalyzerSTTTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitialization() {
        let stt = SpeechAnalyzerSTT()
        XCTAssertFalse(stt.isListening)
        XCTAssertNil(stt.delegate)
        XCTAssertEqual(stt.selectedLanguage, "")
        XCTAssertEqual(stt.selectedModel, "")
    }

    func testDefaultSettings() {
        let stt = SpeechAnalyzerSTT()
        XCTAssertEqual(stt.vadMinimumRecordingTime, 10.0)
        XCTAssertEqual(stt.vadSilenceDuration, 3.0)
        XCTAssertEqual(stt.audioSource, .microphone)
    }

    func testLanguageSelection() {
        let stt = SpeechAnalyzerSTT()

        // Test default (Auto)
        XCTAssertEqual(stt.selectedLanguage, "")

        // Test setting Japanese
        stt.selectedLanguage = "ja"
        XCTAssertEqual(stt.selectedLanguage, "ja")

        // Test setting English
        stt.selectedLanguage = "en"
        XCTAssertEqual(stt.selectedLanguage, "en")
    }

    func testAudioDeviceSelection() {
        let stt = SpeechAnalyzerSTT()

        // Test default (System Default)
        XCTAssertEqual(stt.audioInputDeviceUID, "")

        // Test setting custom device
        stt.audioInputDeviceUID = "TestDeviceUID"
        XCTAssertEqual(stt.audioInputDeviceUID, "TestDeviceUID")
    }

    // MARK: - Protocol Conformance Tests

    func testRealtimeSTTServiceConformance() {
        let stt = SpeechAnalyzerSTT()

        // Verify protocol properties exist
        _ = stt.isListening
        _ = stt.delegate
        _ = stt.selectedModel
        _ = stt.selectedLanguage
        _ = stt.audioInputDeviceUID
        _ = stt.audioSource
        _ = stt.vadMinimumRecordingTime
        _ = stt.vadSilenceDuration

        // If we get here, the protocol is properly implemented
        XCTAssertTrue(true)
    }
}

#endif // compiler(>=6.1)
