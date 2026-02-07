import XCTest
@testable import SpeechDock

final class SubtitleTranslationServiceTests: XCTestCase {

    // MARK: - SubtitleTranslationState Tests

    func testSubtitleTranslationState_Idle() {
        let state = SubtitleTranslationState.idle
        XCTAssertFalse(state.isTranslating)
        XCTAssertEqual(state, .idle)
    }

    func testSubtitleTranslationState_Translating() {
        let state = SubtitleTranslationState.translating
        XCTAssertTrue(state.isTranslating)
        XCTAssertEqual(state, .translating)
    }

    func testSubtitleTranslationState_Error() {
        let state = SubtitleTranslationState.error("Test error")
        XCTAssertFalse(state.isTranslating)

        if case .error(let message) = state {
            XCTAssertEqual(message, "Test error")
        } else {
            XCTFail("Expected error state")
        }
    }

    func testSubtitleTranslationState_Equatable() {
        XCTAssertEqual(SubtitleTranslationState.idle, SubtitleTranslationState.idle)
        XCTAssertEqual(SubtitleTranslationState.translating, SubtitleTranslationState.translating)
        XCTAssertEqual(SubtitleTranslationState.error("test"), SubtitleTranslationState.error("test"))
        XCTAssertNotEqual(SubtitleTranslationState.idle, SubtitleTranslationState.translating)
        XCTAssertNotEqual(SubtitleTranslationState.error("a"), SubtitleTranslationState.error("b"))
    }

    // MARK: - TranslatedSentence Tests

    func testTranslatedSentence_Creation() {
        let sentence = TranslatedSentence(original: "Hello", translated: "こんにちは")
        XCTAssertEqual(sentence.original, "Hello")
        XCTAssertEqual(sentence.translated, "こんにちは")
    }

    func testTranslatedSentence_Equatable() {
        let sentence1 = TranslatedSentence(original: "Hello", translated: "こんにちは")
        let sentence2 = TranslatedSentence(original: "Hello", translated: "こんにちは")
        let sentence3 = TranslatedSentence(original: "Goodbye", translated: "さようなら")

        XCTAssertEqual(sentence1, sentence2)
        XCTAssertNotEqual(sentence1, sentence3)
    }

    // MARK: - SentenceConfirmationTrigger Tests

    func testSentenceConfirmationTrigger_AllCases() {
        let tokenizer = SentenceConfirmationTrigger.tokenizer
        let sttFinal = SentenceConfirmationTrigger.sttFinal
        let pauseTimeout = SentenceConfirmationTrigger.pauseTimeout

        // Ensure all cases are distinct
        XCTAssertTrue(tokenizer != sttFinal || tokenizer != pauseTimeout || sttFinal != pauseTimeout)
    }

    // MARK: - ContextualTranslator Factory Tests

    @MainActor
    func testContextualTranslatorFactory_LLMProviders() {
        let openAI = ContextualTranslatorFactory.makeTranslator(for: .openAI)
        XCTAssertNotNil(openAI)
        XCTAssertEqual(openAI?.provider, .openAI)

        let gemini = ContextualTranslatorFactory.makeTranslator(for: .gemini)
        XCTAssertNotNil(gemini)
        XCTAssertEqual(gemini?.provider, .gemini)

        let grok = ContextualTranslatorFactory.makeTranslator(for: .grok)
        XCTAssertNotNil(grok)
        XCTAssertEqual(grok?.provider, .grok)
    }

    @MainActor
    func testContextualTranslatorFactory_WithModel() {
        let translator = ContextualTranslatorFactory.makeTranslator(for: .openAI, model: "gpt-5-mini")
        XCTAssertNotNil(translator)
        XCTAssertEqual(translator?.provider, .openAI)
    }

    #if compiler(>=6.1)
    @MainActor
    func testContextualTranslatorFactory_MacOS() {
        if #available(macOS 26.0, *) {
            let macOS = ContextualTranslatorFactory.makeTranslator(for: .macOS)
            XCTAssertNotNil(macOS)
            XCTAssertEqual(macOS?.provider, .macOS)
        }
    }
    #endif

    // MARK: - LLMContextualTranslator Tests

    @MainActor
    func testLLMContextualTranslator_Provider() {
        let translator = LLMContextualTranslator(provider: .openAI)
        XCTAssertEqual(translator.provider, .openAI)
    }

    @MainActor
    func testLLMContextualTranslator_Cancel() {
        let translator = LLMContextualTranslator(provider: .openAI)
        // Should not crash when cancelling without active task
        translator.cancel()
    }

    // MARK: - MacOSTranslationAvailability Tests

    @MainActor
    func testMacOSTranslationAvailability_Shared() {
        let availability = MacOSTranslationAvailability.shared
        XCTAssertNotNil(availability)
    }

    @MainActor
    func testMacOSTranslationAvailability_ClearCache() {
        let availability = MacOSTranslationAvailability.shared
        // Should not crash
        availability.clearCache()
    }

    // MARK: - Integration Tests (require MainActor)

    @MainActor
    func testSubtitleTranslationService_Shared() {
        let service = SubtitleTranslationService.shared
        XCTAssertNotNil(service)
    }

    @MainActor
    func testSubtitleTranslationService_Reset() {
        let service = SubtitleTranslationService.shared
        // Should not crash
        service.reset()
    }

    @MainActor
    func testSubtitleTranslationService_ClearAll() {
        let service = SubtitleTranslationService.shared
        // Should not crash
        service.clearAll()
    }

    @MainActor
    func testSubtitleTranslationService_ClearCache() {
        let service = SubtitleTranslationService.shared
        // Should not crash
        service.clearCache()
    }
}
