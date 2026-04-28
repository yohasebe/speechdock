import XCTest
@testable import SpeechDock

final class TranslationServiceTests: XCTestCase {

    // MARK: - TranslationError Tests

    func testTranslationError_NoTextProvided() {
        let error = TranslationError.noTextProvided
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("text"))
    }

    func testTranslationError_LanguageNotSupported() {
        let error = TranslationError.languageNotSupported(.japanese)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Japanese") ||
                     error.errorDescription!.lowercased().contains("support"))
    }

    func testTranslationError_TranslationUnavailable() {
        let error = TranslationError.translationUnavailable("Service temporarily down")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Service temporarily down"))
    }

    func testTranslationError_APIError() {
        let error = TranslationError.apiError("Invalid API key")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Invalid API key"))
    }

    func testTranslationError_Cancelled() {
        let error = TranslationError.cancelled
        XCTAssertNotNil(error.errorDescription)
    }

    // MARK: - TranslationProvider Tests

    func testTranslationProvider_AllCases() {
        let providers = TranslationProvider.allCases
        XCTAssertTrue(providers.contains(.openAI))
        XCTAssertTrue(providers.contains(.gemini))
        XCTAssertTrue(providers.contains(.grok))
        XCTAssertTrue(providers.contains(.macOS))
    }

    func testTranslationProvider_DisplayName() {
        XCTAssertEqual(TranslationProvider.openAI.displayName, "OpenAI")
        XCTAssertEqual(TranslationProvider.gemini.displayName, "Gemini")
        XCTAssertEqual(TranslationProvider.grok.displayName, "Grok")
        XCTAssertEqual(TranslationProvider.macOS.displayName, "macOS")
    }

    func testTranslationProvider_EnvKeyName() {
        XCTAssertEqual(TranslationProvider.openAI.envKeyName, "OPENAI_API_KEY")
        XCTAssertEqual(TranslationProvider.gemini.envKeyName, "GEMINI_API_KEY")
        XCTAssertEqual(TranslationProvider.grok.envKeyName, "GROK_API_KEY")
        XCTAssertNil(TranslationProvider.macOS.envKeyName)
    }

    // MARK: - TranslationResult Tests

    func testTranslationResult_Creation() {
        let result = TranslationResult(
            originalText: "Hello",
            translatedText: "こんにちは",
            sourceLanguage: .english,
            targetLanguage: .japanese,
            provider: .openAI
        )

        XCTAssertEqual(result.originalText, "Hello")
        XCTAssertEqual(result.translatedText, "こんにちは")
        XCTAssertEqual(result.sourceLanguage, .english)
        XCTAssertEqual(result.targetLanguage, .japanese)
        XCTAssertEqual(result.provider, .openAI)
    }

    // MARK: - LanguageCode Tests

    func testLanguageCode_AllCommonLanguages() {
        let codes: [LanguageCode] = [.english, .japanese, .chinese, .korean, .spanish, .french, .german]
        for code in codes {
            XCTAssertFalse(code.displayName.isEmpty, "Language \(code) should have display name")
        }
    }

    func testLanguageCode_DisplayName() {
        XCTAssertEqual(LanguageCode.english.displayName, "English")
        XCTAssertEqual(LanguageCode.japanese.displayName, "日本語")
        XCTAssertEqual(LanguageCode.auto.displayName, "Auto")
    }

    func testLanguageCode_RawValue() {
        XCTAssertEqual(LanguageCode.auto.rawValue, "")  // Auto uses empty string
        XCTAssertEqual(LanguageCode.english.rawValue, "en")
        XCTAssertEqual(LanguageCode.japanese.rawValue, "ja")
    }

    // MARK: - TranslationFactory Tests

    @MainActor
    func testTranslationFactory_MakeService_LLMProviders() {
        // Test that factory creates correct service types for LLM providers
        let openAIService = TranslationFactory.makeService(for: .openAI)
        XCTAssertEqual(openAIService.provider, .openAI)

        let geminiService = TranslationFactory.makeService(for: .gemini)
        XCTAssertEqual(geminiService.provider, .gemini)

        let grokService = TranslationFactory.makeService(for: .grok)
        XCTAssertEqual(grokService.provider, .grok)
    }

    #if compiler(>=6.1)
    @MainActor
    func testTranslationFactory_MakeService_MacOS() {
        let macOSService = TranslationFactory.makeService(for: .macOS)
        XCTAssertEqual(macOSService.provider, .macOS)
    }
    #endif

    // MARK: - TranslationModelInfo Tests

    func testTranslationModelInfo_OpenAI() {
        let models = TranslationProvider.openAI.availableModels
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "gpt-5.4-mini")
        XCTAssertTrue(models[0].isDefault)
        XCTAssertEqual(models[1].id, "gpt-5.4-nano")
        XCTAssertFalse(models[1].isDefault)
    }

    func testTranslationModelInfo_Gemini() {
        let models = TranslationProvider.gemini.availableModels
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "gemini-3.1-flash-lite-preview")
        XCTAssertTrue(models[0].isDefault)
        XCTAssertEqual(models[1].id, "gemini-3.1-pro-preview")
        XCTAssertFalse(models[1].isDefault)
    }

    func testTranslationModelInfo_Grok() {
        let models = TranslationProvider.grok.availableModels
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "grok-4.1-fast-non-reasoning")
        XCTAssertTrue(models[0].isDefault)
        XCTAssertEqual(models[1].id, "grok-4.1-fast-reasoning")
        XCTAssertFalse(models[1].isDefault)
    }

    func testTranslationModelInfo_MacOS() {
        let models = TranslationProvider.macOS.availableModels
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "system")
        XCTAssertTrue(models[0].isDefault)
    }

    func testTranslationProvider_DefaultModelId() {
        XCTAssertEqual(TranslationProvider.openAI.defaultModelId, "gpt-5.4-mini")
        XCTAssertEqual(TranslationProvider.gemini.defaultModelId, "gemini-3.1-flash-lite-preview")
        XCTAssertEqual(TranslationProvider.grok.defaultModelId, "grok-4.1-fast-non-reasoning")
        XCTAssertEqual(TranslationProvider.macOS.defaultModelId, "system")
    }

    @MainActor
    func testTranslationFactory_MakeService_WithModel() {
        let service = TranslationFactory.makeService(for: .openAI, model: "gpt-5.4-nano")
        XCTAssertEqual(service.provider, .openAI)
        if let llmService = service as? LLMTranslation {
            XCTAssertEqual(llmService.model, "gpt-5.4-nano")
        } else {
            XCTFail("Expected LLMTranslation instance")
        }
    }

    @MainActor
    func testTranslationFactory_MakeService_DefaultModel() {
        let service = TranslationFactory.makeService(for: .gemini)
        if let llmService = service as? LLMTranslation {
            XCTAssertEqual(llmService.model, "gemini-3.1-flash-lite-preview")
        } else {
            XCTFail("Expected LLMTranslation instance")
        }
    }

    // MARK: - TranslationState Tests

    func testTranslationState_Equatable() {
        XCTAssertEqual(TranslationState.idle, TranslationState.idle)
        XCTAssertEqual(TranslationState.translating, TranslationState.translating)
        XCTAssertNotEqual(TranslationState.idle, TranslationState.translating)
    }

    func testTranslationState_IsTranslated() {
        XCTAssertFalse(TranslationState.idle.isTranslated)
        XCTAssertFalse(TranslationState.translating.isTranslated)
        XCTAssertTrue(TranslationState.translated("翻訳済みテキスト").isTranslated)
    }

    func testTranslationState_TranslatedText() {
        let state = TranslationState.translated("Hello World")
        XCTAssertEqual(state.translatedText, "Hello World")
        XCTAssertNil(TranslationState.idle.translatedText)
    }
}
