import XCTest
@testable import SpeechDock

/// Tests for ElevenLabs STT text deduplication logic
final class ElevenLabsDeduplicationTests: XCTestCase {

    // MARK: - Deduplication Logic Tests

    /// Simulates the deduplication logic from ElevenLabsRealtimeSTT
    private func applyDeduplication(committedText: inout String, newText: String) {
        if committedText.isEmpty {
            committedText = newText
        } else if !committedText.hasSuffix(newText) && !committedText.contains(newText) {
            committedText += " " + newText
        }
        // else: skip duplicate
    }

    func testEmptyCommittedText() {
        var committedText = ""
        applyDeduplication(committedText: &committedText, newText: "Hello world")

        XCTAssertEqual(committedText, "Hello world")
    }

    func testAppendNewText() {
        var committedText = "Hello"
        applyDeduplication(committedText: &committedText, newText: "world")

        XCTAssertEqual(committedText, "Hello world")
    }

    func testSkipDuplicateSuffix() {
        // When the new text is the same as the end of committed text
        var committedText = "Hello world"
        applyDeduplication(committedText: &committedText, newText: "world")

        // Should not append duplicate
        XCTAssertEqual(committedText, "Hello world")
    }

    func testSkipContainedText() {
        // When the new text is contained somewhere in committed text
        var committedText = "Hello world today"
        applyDeduplication(committedText: &committedText, newText: "world")

        // Should not append duplicate
        XCTAssertEqual(committedText, "Hello world today")
    }

    func testSkipExactDuplicate() {
        // When the entire committed text is sent again
        var committedText = "Hello world"
        applyDeduplication(committedText: &committedText, newText: "Hello world")

        // Should not append duplicate (contains check catches this)
        XCTAssertEqual(committedText, "Hello world")
    }

    func testAppendDifferentText() {
        // When new text is genuinely different
        var committedText = "Hello"
        applyDeduplication(committedText: &committedText, newText: "Goodbye")

        XCTAssertEqual(committedText, "Hello Goodbye")
    }

    func testPartialOverlapNotDuplicate() {
        // When new text partially overlaps but isn't contained
        var committedText = "Hello world"
        applyDeduplication(committedText: &committedText, newText: "world again")

        // "world again" is not entirely contained in "Hello world"
        // but "world" is a suffix, so hasSuffix("world again") is false
        // and contains("world again") is also false
        // So this should be appended
        XCTAssertEqual(committedText, "Hello world world again")
    }

    func testCaseSensitiveComparison() {
        // Deduplication should be case-sensitive
        var committedText = "Hello World"
        applyDeduplication(committedText: &committedText, newText: "world")

        // "world" != "World", so it should be appended
        XCTAssertEqual(committedText, "Hello World world")
    }

    func testMultipleSequentialAppends() {
        var committedText = ""

        applyDeduplication(committedText: &committedText, newText: "First")
        XCTAssertEqual(committedText, "First")

        applyDeduplication(committedText: &committedText, newText: "Second")
        XCTAssertEqual(committedText, "First Second")

        applyDeduplication(committedText: &committedText, newText: "Third")
        XCTAssertEqual(committedText, "First Second Third")
    }

    func testDuplicateAfterMultipleAppends() {
        var committedText = ""

        applyDeduplication(committedText: &committedText, newText: "Hello")
        applyDeduplication(committedText: &committedText, newText: "world")
        applyDeduplication(committedText: &committedText, newText: "world")  // duplicate

        // Should not double-append "world"
        XCTAssertEqual(committedText, "Hello world")
    }

    // MARK: - Edge Cases

    func testEmptyNewText() {
        // Empty new text should be handled before this logic in the actual code
        // In ElevenLabsRealtimeSTT, empty text is filtered with: if let text = ..., !text.isEmpty
        // This test verifies Swift's String.contains behavior with empty strings
        let committedText = "Hello"

        // Swift's String.contains("") returns false (unlike some other languages)
        // This means empty strings would be appended if not filtered beforehand
        // The actual code filters empty text before deduplication, so this is safe
        XCTAssertFalse(committedText.contains(""))
    }

    func testWhitespaceHandling() {
        var committedText = "Hello"
        applyDeduplication(committedText: &committedText, newText: " ")

        // Single space is not contained (without considering the joining space)
        // Actually " " is contained in nothing initially
        // But after "Hello" + " " + " " = "Hello  "
        // Wait, let me check - " " is not a suffix of "Hello" and
        // " " is not contained in "Hello"
        // So it would be appended: "Hello" + " " + " " = "Hello  "
        // Actually the joining adds " " so result is "Hello  " (two spaces)
        // Actually wait - the new text is " " (single space)
        // hasSuffix(" ") is false for "Hello"
        // contains(" ") is false for "Hello"
        // So we append: "Hello" + " " + " " = "Hello  "
        XCTAssertEqual(committedText, "Hello  ")
    }

    func testJapaneseText() {
        var committedText = ""

        applyDeduplication(committedText: &committedText, newText: "こんにちは")
        XCTAssertEqual(committedText, "こんにちは")

        applyDeduplication(committedText: &committedText, newText: "世界")
        XCTAssertEqual(committedText, "こんにちは 世界")

        // Duplicate should be skipped
        applyDeduplication(committedText: &committedText, newText: "世界")
        XCTAssertEqual(committedText, "こんにちは 世界")
    }

    func testMixedLanguageText() {
        var committedText = "Hello"

        applyDeduplication(committedText: &committedText, newText: "世界")
        XCTAssertEqual(committedText, "Hello 世界")

        applyDeduplication(committedText: &committedText, newText: "again")
        XCTAssertEqual(committedText, "Hello 世界 again")
    }

    func testLongTextDeduplication() {
        let longText = String(repeating: "word ", count: 100).trimmingCharacters(in: .whitespaces)
        var committedText = longText

        // Trying to append the same long text should skip
        applyDeduplication(committedText: &committedText, newText: longText)
        XCTAssertEqual(committedText, longText)
    }

    // MARK: - Real-World Scenarios

    func testRealisticElevenLabsBehavior() {
        // Simulate a realistic ElevenLabs streaming session
        var committedText = ""

        // First committed transcript
        applyDeduplication(committedText: &committedText, newText: "Today we're going to discuss")
        XCTAssertEqual(committedText, "Today we're going to discuss")

        // Second committed transcript (new content)
        applyDeduplication(committedText: &committedText, newText: "the importance of testing")
        XCTAssertEqual(committedText, "Today we're going to discuss the importance of testing")

        // ElevenLabs sometimes resends previous content
        applyDeduplication(committedText: &committedText, newText: "Today we're going to discuss")
        // Should be skipped (contained)
        XCTAssertEqual(committedText, "Today we're going to discuss the importance of testing")

        // New content continues
        applyDeduplication(committedText: &committedText, newText: "in software development")
        XCTAssertEqual(committedText, "Today we're going to discuss the importance of testing in software development")
    }

    func testPartialResend() {
        // When ElevenLabs resends just the last phrase
        var committedText = "Testing is important"

        // Resend of suffix
        applyDeduplication(committedText: &committedText, newText: "important")
        XCTAssertEqual(committedText, "Testing is important")  // No change

        // New content
        applyDeduplication(committedText: &committedText, newText: "for quality")
        XCTAssertEqual(committedText, "Testing is important for quality")
    }
}
