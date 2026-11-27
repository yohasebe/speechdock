import XCTest
@testable import SpeechDock

final class TextStatisticsTests: XCTestCase {
    func testCountsWordsSeparatedBySpacesAndLines() {
        XCTAssertEqual(TextStatistics.wordCount("one two  three\nfour"), 4)
    }

    func testDoesNotCountPunctuationOrWhitespace() {
        XCTAssertEqual(TextStatistics.wordCount("Hello, world!"), 2)
        XCTAssertEqual(TextStatistics.wordCount(" \n\t "), 0)
        XCTAssertEqual(TextStatistics.wordCount(""), 0)
    }

    func testCountsWordsInTextWrittenWithoutSpaces() {
        XCTAssertGreaterThan(TextStatistics.wordCount("私は猫が好きです"), 1)
        XCTAssertGreaterThan(TextStatistics.wordCount("我喜欢猫"), 1)
    }
}
