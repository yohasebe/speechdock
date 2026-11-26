import XCTest
@testable import SpeechDock

@MainActor
final class SubtitleTranslationRecoveryTests: XCTestCase {

    /// A result arriving after reset() (e.g. Live OCR restarting translation) used to leave
    /// the service "translating" for good, so every later line queued and nothing translated.
    func testLateResultAfterResetDoesNotBlockNextLine() async {
        let app = AppState(startServices: false)
        app.selectedSTTLanguage = "en"
        app.translationProvider = .openAI
        app.translationTargetLanguage = .japanese
        app.subtitleTranslationEnabled = true
        let translator = ControllableTranslator()
        let service = SubtitleTranslationService(makeTranslator: { _, _ in translator })

        let first = Task { await service.processTextUpdate("one", isFinal: true, appState: app) }
        await settle()
        XCTAssertEqual(translator.requests, ["one"])
        service.reset()
        translator.complete("いち")
        await first.value

        let second = Task { await service.processTextUpdate("two", isFinal: true, appState: app) }
        await settle()
        XCTAssertEqual(translator.requests, ["one", "two"], "the next line is translated, not queued forever")
        translator.complete("に")
        await second.value
        XCTAssertEqual(app.subtitleTranslatedText, "に")
        XCTAssertEqual(app.subtitleTranslationState, .idle)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private final class ControllableTranslator: ContextualTranslator {
    let provider: TranslationProvider = .openAI
    private(set) var requests: [String] = []
    private var continuation: CheckedContinuation<String, Error>?

    func translate(text: String, context: [TranslatedSentence], to targetLanguage: LanguageCode) async throws -> String {
        requests.append(text)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancel() {}
    func complete(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}
