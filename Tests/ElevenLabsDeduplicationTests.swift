import XCTest
@testable import SpeechDock

/// Tests for which ElevenLabs committed events add a segment.
final class ElevenLabsDeduplicationTests: XCTestCase {
    private let plain = "committed_transcript"
    private let stamped = "committed_transcript_with_timestamps"

    private func added(_ events: [String]) -> [Bool] {
        var counter = CommittedSegmentCounter()
        return events.map { counter.isNewSegment(messageType: $0) }
    }

    func testEachSegmentReportedTwiceIsAddedOnce() {
        XCTAssertEqual(added([plain, stamped, plain, stamped]), [true, false, true, false])
    }

    func testTimestampedCopyArrivingAfterNextSegment() {
        // Segment 1 plain, segment 2 plain, then both timestamped copies.
        XCTAssertEqual(added([plain, plain, stamped, stamped]), [true, true, false, false])
    }

    func testTimestampedCopyArrivingFirst() {
        XCTAssertEqual(added([stamped, plain, plain, stamped]), [true, false, true, false])
    }

    func testOnlyOneKindAddsEverySegment() {
        XCTAssertEqual(added([plain, plain, plain]), [true, true, true])
        XCTAssertEqual(added([stamped, stamped]), [true, true])
    }

    func testRepeatedPhraseIsNotDropped() {
        // The counter never compares text, so "はい" spoken twice is two segments.
        XCTAssertEqual(added([plain, stamped, plain, stamped]).filter { $0 }.count, 2)
    }
}

/// Tests for the language_code sent to ElevenLabs text-to-speech.
final class ElevenLabsLanguageCodeTests: XCTestCase {
    func testSendsISO6391Codes() {
        XCTAssertEqual(ElevenLabsTTS.languageCodeParameter(modelId: "eleven_flash_v2_5", selectedLanguage: "ja"), "ja")
        XCTAssertEqual(ElevenLabsTTS.languageCodeParameter(modelId: "eleven_v3", selectedLanguage: "zh"), "zh")
    }

    func testAutoAndUnsupportedModelSendNothing() {
        XCTAssertNil(ElevenLabsTTS.languageCodeParameter(modelId: "eleven_flash_v2_5", selectedLanguage: ""))
        XCTAssertNil(ElevenLabsTTS.languageCodeParameter(modelId: "eleven_multilingual_v2", selectedLanguage: "ja"))
        XCTAssertNil(ElevenLabsTTS.languageCodeParameter(modelId: "eleven_v3", selectedLanguage: "not-a-language"))
    }
}
