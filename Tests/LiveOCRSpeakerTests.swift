import XCTest
@testable import SpeechDock

@MainActor
final class LiveOCRSpeakerTests: XCTestCase {

    func testNextLineIsFetchedWhileCurrentLinePlays() async {
        let tts = PrefetchingTTS()
        let speaker = LiveOCRSpeaker { tts }

        speaker.enqueue("one")
        await settle()
        tts.finishSynthesis("one")
        await settle()
        XCTAssertEqual(tts.played, ["one"])

        // "two" arrives mid-playback: its audio is requested right away.
        speaker.enqueue("two")
        await settle()
        XCTAssertEqual(tts.synthesisRequests, ["one", "two"])
        tts.finishSynthesis("two")
        await settle()
        XCTAssertEqual(tts.played, ["one"], "must not cut off the line that is playing")

        tts.finishPlayback()
        await settle()
        XCTAssertEqual(tts.played, ["one", "two"])
    }

    func testOnlyNewestWaitingLineIsSpoken() async {
        let tts = PrefetchingTTS()
        let speaker = LiveOCRSpeaker { tts }

        speaker.enqueue("one")
        await settle()
        tts.finishSynthesis("one")
        await settle()
        speaker.enqueue("two")
        speaker.enqueue("three")
        await settle()
        tts.finishSynthesis("three")
        tts.finishPlayback()
        await settle()
        XCTAssertEqual(tts.played, ["one", "three"])
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private final class PrefetchingTTS: PresynthesizingTTSService {
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

    private(set) var synthesisRequests: [String] = []
    private(set) var played: [String] = []
    private var pending: [String: CheckedContinuation<PreparedSpeech, Error>] = [:]

    func synthesize(text: String) async throws -> PreparedSpeech {
        synthesisRequests.append(text)
        return try await withCheckedThrowingContinuation { pending[text] = $0 }
    }

    func finishSynthesis(_ text: String) {
        pending.removeValue(forKey: text)?.resume(returning: PreparedSpeech(text: text, data: Data(), fileExtension: "wav"))
    }

    func play(_ speech: PreparedSpeech) throws {
        played.append(speech.text)
        delegate?.ttsDidStartSpeaking(self)
    }

    func finishPlayback() { delegate?.tts(self, didFinishSpeaking: true) }

    func speak(text: String) async throws { XCTFail("prefetching path expected") }
    func stop() {}
    func pause() {}
    func resume() {}
    func setPlaybackRate(_ rate: Float) {}
    func clearAudioCache() {}
    func availableVoices() -> [TTSVoice] { [] }
    func availableModels() -> [TTSModelInfo] { [] }
    func speedRange() -> ClosedRange<Double> { 0.5...2 }
}
