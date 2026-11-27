import XCTest
import AVFoundation
@testable import SpeechDock

final class RegressionTests: XCTestCase {
    @MainActor
    func testHighlightRangesWithEmojiCombiningMarksAndWhitespace() {
        for text in ["👨‍👩‍👧‍👦 a", "😀 hello world", "e\u{301} cafe\n日本語", "  one\t two\n", ""] {
            let ranges = TTSAudioPlaybackController.calculateWordRanges(for: text)
            let words = ranges.map { (text as NSString).substring(with: $0) }
            XCTAssertEqual(words, text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        }
    }

    func testModelSelectionAcrossProviderLists() {
        for ids in [["default"], ["one", "two"], []] {
            let fallback = ids.first ?? ""
            for invalid in ["", "retired", "unknown"] {
                XCTAssertEqual(ModelSelection.resolve(invalid, availableIDs: ids, defaultID: fallback), fallback)
            }
            for id in ids { XCTAssertEqual(ModelSelection.resolve(id, availableIDs: ids, defaultID: fallback), id) }
        }
    }

    func testAudioSignaturesAndOriginalExtensionFallback() {
        let fixtures: [(Data, String, String)] = [
            (Data("fLaC".utf8), "flac", "audio/flac"),
            (Data([0xff, 0xf1, 0x50, 0x80]), "aac", "audio/aac"),
            (Data([0xff, 0xf9, 0x50, 0x80]), "aac", "audio/aac"),
            (Data("FORM0000AIFF".utf8), "aiff", "audio/aiff"),
            (Data("FORM0000AIFC".utf8), "aiff", "audio/aiff"),
            (Data([0xff, 0xfb, 0x90, 0]), "mp3", "audio/mpeg")
        ]
        for (data, ext, mime) in fixtures {
            let format = AudioFormatConverter.normalizeFormat(data, originalExtension: "m4a")
            XCTAssertEqual(format.fileExtension, ext)
            XCTAssertEqual(format.mimeType, mime)
        }
        for ext in ["flac", "aac", "aiff", "webm"] {
            let format = AudioFormatConverter.normalizeFormat(Data(), originalExtension: ext.uppercased())
            XCTAssertEqual(format.fileExtension, ext)
            XCTAssertEqual(AudioFormatConverter.mimeTypeForGemini(from: format), format.mimeType)
        }
    }

    @MainActor
    func testFinalizationWaitsForTrailingResultAndDetachesDelegate() async {
        let service = FinishingSTT()
        let result = await STTFinalization.finish(service, initialText: "partial")
        XCTAssertEqual(result, "final result")
        XCTAssertTrue(service.finished)
        XCTAssertNil(service.delegate)
    }

    @MainActor
    func testFinalizationPreservesLastPartialWhenNoFinalArrives() async {
        let service = FinishingSTT()
        service.finalText = nil
        let result = await STTFinalization.finish(service, initialText: " partial ")
        XCTAssertEqual(result, "partial")
    }

    @MainActor
    func testSynthesisGenerationRejectsLateResponse() async {
        let lifecycle = SynthesisLifecycle()
        let old = lifecycle.generation
        lifecycle.invalidate()
        XCTAssertThrowsError(try lifecycle.check(old))
        XCTAssertNoThrow(try lifecycle.check(lifecycle.generation))
    }

    @MainActor
    func testStoppedTTSRejectsLateDelegateAndResponse() async {
        let app = AppState(startServices: false)
        let service = DelayedTTS()
        let started = expectation(description: "request started")
        service.started = { started.fulfill() }
        app.ttsServiceFactory = { _ in service }
        app.ttsText = "hello world"
        app.speakCurrentText()
        await fulfillment(of: [started], timeout: 1)
        let oldDelegate = service.delegate
        app.stopTTS()
        service.complete()
        oldDelegate?.ttsDidStartSpeaking(service)
        oldDelegate?.tts(service, didFailWithError: TTSError.audioError("late error"))
        await Task.yield()
        XCTAssertEqual(app.ttsState, .idle)
        XCTAssertNil(service.delegate)
    }

    @MainActor
    func testOldAudioPlayerCallbacksDoNotFinishCurrentController() async throws {
        let controller = TTSAudioPlaybackController()
        let old = try AVAudioPlayer(data: AudioConverter.createWAVFromPCM(Data(repeating: 0, count: 4800)))
        var completions = 0
        controller.onFinishSpeaking = { _ in completions += 1 }
        controller.onError = { _ in completions += 1 }
        controller.audioPlayerDidFinishPlaying(old, successfully: true)
        controller.audioPlayerDecodeErrorDidOccur(old, error: TTSError.audioError("stale"))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(completions, 0)
    }

    func testAudioCacheIncludesEverySynthesisInput() {
        func key(provider: TTSProvider = .gemini, model: String = "flash", voice: String = "zephyr",
                 speed: Double = 1, language: String = "", rules: [TextReplacementRule] = [],
                 settings: [BuiltInPattern: BuiltInPatternSetting] = [:]) -> TTSAudioCacheKey {
            TTSAudioCacheKey(text: "hello world", provider: provider, model: model, voice: voice,
                            speed: speed, language: language, rules: rules, builtInSettings: settings)
        }
        let baseline = key()
        for changed in [key(provider: .openAI), key(model: "lite"), key(voice: "kore"),
                        key(speed: 1.5), key(language: "ja"),
                        key(rules: [TextReplacementRule(find: "world", replace: "earth")]),
                        key(settings: [.url: BuiltInPatternSetting(isEnabled: true, replacement: "link")])] {
            XCTAssertNotEqual(baseline, changed)
        }
        XCTAssertEqual(baseline, key())
    }

    @MainActor
    func testSubtitleLanguageChangeRejectsInFlightResult() async {
        let app = AppState(startServices: false)
        app.selectedSTTLanguage = "en"
        app.translationProvider = .openAI
        app.translationTargetLanguage = .japanese
        app.subtitleTranslationEnabled = true
        let translator = DelayedTranslator()
        let service = SubtitleTranslationService(makeTranslator: { _, _ in translator })
        let started = expectation(description: "translation started")
        translator.started = { started.fulfill() }
        let task = Task { await service.processTextUpdate("hello", isFinal: true, appState: app) }
        await fulfillment(of: [started], timeout: 1)
        app.translationTargetLanguage = .french
        translator.complete("古い結果")
        await task.value
        XCTAssertEqual(app.subtitleTranslatedText, "")
        XCTAssertEqual(app.subtitleTranslationState, .idle)
    }

    @MainActor
    func testSubtitleResetRejectsInFlightError() async {
        let app = AppState(startServices: false)
        app.selectedSTTLanguage = "en"
        app.translationProvider = .openAI
        app.subtitleTranslationEnabled = true
        let translator = DelayedTranslator()
        let service = SubtitleTranslationService(makeTranslator: { _, _ in translator })
        let started = expectation(description: "translation started")
        translator.started = { started.fulfill() }
        let task = Task { await service.processTextUpdate("hello", isFinal: true, appState: app) }
        await fulfillment(of: [started], timeout: 1)
        service.invalidate(appState: app)
        translator.fail()
        await task.value
        XCTAssertEqual(app.subtitleTranslationState, .idle)
    }

    @MainActor
    func testSubtitleResetDoesNotLeaveLaterLinesWaiting() async {
        let app = AppState(startServices: false)
        app.selectedSTTLanguage = "en"
        app.translationProvider = .openAI
        app.translationTargetLanguage = .japanese
        app.subtitleTranslationEnabled = true
        let translator = DelayedTranslator()
        let service = SubtitleTranslationService(makeTranslator: { _, _ in translator })

        let firstStarted = expectation(description: "first translation started")
        translator.started = { firstStarted.fulfill() }
        let first = Task { await service.processTextUpdate("hello", isFinal: true, appState: app) }
        await fulfillment(of: [firstStarted], timeout: 1)
        service.reset()  // e.g. a new recording starts; the old result is now out of date
        translator.complete("古い結果")
        await first.value
        XCTAssertEqual(app.subtitleTranslationState, .idle)
        XCTAssertEqual(app.subtitleTranslatedText, "")

        let secondStarted = expectation(description: "next line is translated")
        translator.started = { secondStarted.fulfill() }
        let second = Task { await service.processTextUpdate("world", isFinal: true, appState: app) }
        await fulfillment(of: [secondStarted], timeout: 1)
        translator.complete("世界")
        await second.value
        XCTAssertEqual(app.subtitleTranslatedText, "世界")
    }

    @MainActor
    func testResumeThatFailsAtOnceKeepsTheError() async {
        let app = AppState(startServices: false)
        let service = DelayedTTS()
        let started = expectation(description: "request started")
        service.started = { started.fulfill() }
        app.ttsServiceFactory = { _ in service }
        app.ttsText = "hello world"
        app.speakCurrentText()
        await fulfillment(of: [started], timeout: 1)
        service.complete()
        await Task.yield()

        service.isPaused = true
        app.ttsState = .paused
        service.onResume = { service.delegate?.tts(service, didFailWithError: TTSError.audioError("output changed")) }
        app.pauseResumeTTS()

        if case .error = app.ttsState {} else { XCTFail("expected the error to stay, got \(app.ttsState)") }
    }

    @MainActor
    func testLineQueuedDuringASuccessfulRequestIsTranslatedNext() async {
        let app = AppState(startServices: false)
        app.selectedSTTLanguage = "en"
        app.translationProvider = .openAI
        app.translationTargetLanguage = .japanese
        app.subtitleTranslationEnabled = true
        let translator = DelayedTranslator()
        let service = SubtitleTranslationService(makeTranslator: { _, _ in translator })

        let firstStarted = expectation(description: "first translation started")
        translator.started = { firstStarted.fulfill() }
        let first = Task { await service.processTextUpdate("hello", isFinal: true, appState: app) }
        await fulfillment(of: [firstStarted], timeout: 1)
        await service.processTextUpdate("hello world", isFinal: true, appState: app)  // queued

        let nextStarted = expectation(description: "queued line follows")
        translator.started = { nextStarted.fulfill() }
        translator.complete("こんにちは")
        await first.value
        await fulfillment(of: [nextStarted], timeout: 1)
        translator.complete("こんにちは世界")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.subtitleTranslatedText, "こんにちは世界")
    }

    @MainActor
    func testResetDropsALineQueuedBeforeIt() async {
        let app = AppState(startServices: false)
        app.selectedSTTLanguage = "en"
        app.translationProvider = .openAI
        app.translationTargetLanguage = .japanese
        app.subtitleTranslationEnabled = true
        let translator = DelayedTranslator()
        let service = SubtitleTranslationService(makeTranslator: { _, _ in translator })

        let firstStarted = expectation(description: "first translation started")
        translator.started = { firstStarted.fulfill() }
        let first = Task { await service.processTextUpdate("hello", isFinal: true, appState: app) }
        await fulfillment(of: [firstStarted], timeout: 1)
        await service.processTextUpdate("old line", isFinal: true, appState: app)  // queued
        service.reset()  // the queued line belongs to the session that ended

        var startedAgain = false
        translator.started = { startedAgain = true }
        translator.complete("古い結果")
        await first.value
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(startedAgain)
        XCTAssertEqual(app.subtitleTranslationState, .idle)
    }

    @MainActor
    func testLineQueuedBehindADiscardedRequestIsTranslated() async {
        let app = AppState(startServices: false)
        app.selectedSTTLanguage = "en"
        app.translationProvider = .openAI
        app.translationTargetLanguage = .japanese
        app.subtitleTranslationEnabled = true
        let translator = DelayedTranslator()
        let service = SubtitleTranslationService(makeTranslator: { _, _ in translator })

        let firstStarted = expectation(description: "first translation started")
        translator.started = { firstStarted.fulfill() }
        let first = Task { await service.processTextUpdate("hello", isFinal: true, appState: app) }
        await fulfillment(of: [firstStarted], timeout: 1)
        service.reset()

        // The last line of the new session arrives while the old request is still out.
        await service.processTextUpdate("world", isFinal: true, appState: app)
        let queuedStarted = expectation(description: "queued line is translated without another update")
        translator.started = { queuedStarted.fulfill() }
        translator.complete("古い結果")
        await first.value
        await fulfillment(of: [queuedStarted], timeout: 1)
        translator.complete("世界")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.subtitleTranslatedText, "世界")
    }
}

@MainActor
private final class FinishingSTT: RealtimeSTTService {
    weak var delegate: RealtimeSTTDelegate?
    var isListening = true
    var selectedModel = "test"
    var selectedLanguage = ""
    var audioInputDeviceUID = ""
    var audioSource: STTAudioSource = .microphone
    var vadMinimumRecordingTime: TimeInterval = 0
    var vadSilenceDuration: TimeInterval = 0
    var finished = false
    var finalText: String? = "final result"
    func startListening() async throws {}
    func stopListening() { isListening = false }
    func finishListening() async {
        stopListening()
        await Task.yield()
        if let finalText { delegate?.realtimeSTT(self, didReceiveFinalResult: finalText) }
        finished = true
    }
    func availableModels() -> [RealtimeSTTModelInfo] { [] }
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {}
}

@MainActor
private final class DelayedTTS: TTSService {
    weak var delegate: TTSDelegate?
    var isSpeaking = false
    var isPaused = false
    var selectedVoice = ""
    var selectedModel = ""
    var selectedSpeed: Double = 1
    var selectedLanguage = ""
    var audioOutputDeviceUID = ""
    var lastAudioData: Data?
    var audioFileExtension = "wav"
    var supportsSpeedControl = true
    var useStreamingMode = false
    var started: (() -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    func speak(text: String) async throws {
        await withCheckedContinuation { continuation = $0; started?() }
        lastAudioData = Data([0, 0])
        delegate?.ttsDidStartSpeaking(self)
    }
    func complete() { continuation?.resume(); continuation = nil }
    func stop() {}
    func pause() {}
    var onResume: (() -> Void)?
    func resume() { onResume?() }
    func setPlaybackRate(_ rate: Float) {}
    func clearAudioCache() { lastAudioData = nil }
    func availableVoices() -> [TTSVoice] { [] }
    func availableModels() -> [TTSModelInfo] { [] }
    func speedRange() -> ClosedRange<Double> { 0.5...2 }
}

@MainActor
private final class DelayedTranslator: ContextualTranslator {
    let provider: TranslationProvider = .openAI
    var started: (() -> Void)?
    var continuation: CheckedContinuation<String, Error>?
    func translate(text: String, context: [TranslatedSentence], to targetLanguage: LanguageCode) async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0; started?() }
    }
    func cancel() {} // Deliberately simulate a transport that ignores cancellation.
    func complete(_ text: String) { continuation?.resume(returning: text); continuation = nil }
    func fail() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}
