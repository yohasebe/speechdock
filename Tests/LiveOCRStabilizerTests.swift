import XCTest
@testable import SpeechDock

final class LiveOCRStabilizerTests: XCTestCase {

    func testCommitsAfterTwoMatchingReads() {
        var stabilizer = LiveOCRStabilizer()
        XCTAssertNil(stabilizer.ingest("Where are you going?"))
        XCTAssertEqual(stabilizer.ingest("Where are you going?"), "Where are you going?")
        // Same subtitle staying on screen is not reported again.
        XCTAssertNil(stabilizer.ingest("Where are you going?"))
    }

    func testReportsWhileANewLineAwaitsConfirmation() {
        var stabilizer = LiveOCRStabilizer()
        XCTAssertFalse(stabilizer.isConfirming)
        _ = stabilizer.ingest("Run!")
        XCTAssertTrue(stabilizer.isConfirming, "the session then re-reads sooner than a full interval")
        _ = stabilizer.ingest("Run!")
        XCTAssertFalse(stabilizer.isConfirming)
    }

    func testOCRJitterCountsAsTheSameLine() {
        var stabilizer = LiveOCRStabilizer()
        _ = stabilizer.ingest("I told you already.")
        XCTAssertEqual(stabilizer.ingest("I told you alreadv."), "I told you alreadv.")
        XCTAssertNil(stabilizer.ingest("I told you already."))
    }

    func testFadeInFrameIsNotReported() {
        var stabilizer = LiveOCRStabilizer()
        XCTAssertNil(stabilizer.ingest("Th"))
        XCTAssertNil(stabilizer.ingest("The ship is leaving"))
        XCTAssertEqual(stabilizer.ingest("The ship is leaving"), "The ship is leaving")
    }

    func testClearsAfterTextDisappears() {
        var stabilizer = LiveOCRStabilizer()
        _ = stabilizer.ingest("Hello")
        _ = stabilizer.ingest("Hello")
        XCTAssertNil(stabilizer.ingest(""))
        XCTAssertNil(stabilizer.ingest(""))
        XCTAssertEqual(stabilizer.ingest(""), "")
        XCTAssertEqual(stabilizer.committed, "")
    }

    func testBriefDropoutDoesNotClear() {
        var stabilizer = LiveOCRStabilizer()
        _ = stabilizer.ingest("Hello")
        _ = stabilizer.ingest("Hello")
        XCTAssertNil(stabilizer.ingest(""))
        XCTAssertNil(stabilizer.ingest("Hello"))
        XCTAssertEqual(stabilizer.committed, "Hello")
    }

    func testNormalizeCollapsesWhitespaceAndKeepsLines() {
        XCTAssertEqual(LiveOCRStabilizer.normalize("  - Hi   there \n\n  - Hey "), "- Hi there\n- Hey")
    }

    func testDifferentShortLinesAreNotSimilar() {
        XCTAssertFalse(LiveOCRStabilizer.isSimilar("Yes.", "No."))
        XCTAssertTrue(LiveOCRStabilizer.isSimilar("Okay", "okay"))
    }

    func testFrameFingerprintComparison() {
        let a = [UInt8](repeating: 100, count: 64)
        var b = a
        b[0] = 110
        XCTAssertTrue(LiveOCRSession.isSameFrame(a, b))
        XCTAssertFalse(LiveOCRSession.isSameFrame(a, [UInt8](repeating: 140, count: 64)))
    }
}
