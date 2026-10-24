import AVFoundation
import XCTest
@testable import SpeechDock

@MainActor
final class AudioConfigurationChangeTests: XCTestCase {

    private final class StubSTT: RealtimeSTTService {
        weak var delegate: RealtimeSTTDelegate?
        var isListening = true
        var selectedModel = "test"
        var selectedLanguage = ""
        var audioInputDeviceUID = ""
        var audioSource: STTAudioSource = .microphone
        var vadMinimumRecordingTime: TimeInterval = 0
        var vadSilenceDuration: TimeInterval = 0
        var stopCount = 0
        func startListening() async throws {}
        func stopListening() {
            stopCount += 1
            isListening = false
            delegate?.realtimeSTT(self, didChangeListeningState: false)
        }
        func availableModels() -> [RealtimeSTTModelInfo] { [] }
        func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {}
    }

    private final class RecordingDelegate: RealtimeSTTDelegate {
        var events: [String] = []
        var errors: [Error] = []
        func realtimeSTT(_ service: RealtimeSTTService, didReceivePartialResult text: String) {}
        func realtimeSTT(_ service: RealtimeSTTService, didReceiveFinalResult text: String) { events.append("final:" + text) }
        func realtimeSTT(_ service: RealtimeSTTService, didFailWithError error: Error) { events.append("error"); errors.append(error) }
        func realtimeSTT(_ service: RealtimeSTTService, didChangeListeningState isListening: Bool) {
            if !isListening { events.append("stopped") }
        }
    }

    func testObserverFiresOnlyForItsEngineUntilReleased() {
        let engine = AVAudioEngine()
        let otherEngine = AVAudioEngine()
        var calls = 0
        var observer: AudioEngineConfigurationObserver? = AudioEngineConfigurationObserver(engine: engine) {
            calls += 1
        }
        XCTAssertNotNil(observer)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: otherEngine)
        XCTAssertEqual(calls, 0)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(calls, 1)

        observer = nil
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(calls, 1)
    }

    func testStoppedEngineEndsListeningSessionWithError() throws {
        let stt = StubSTT()
        let delegate = RecordingDelegate()
        stt.delegate = delegate

        // A never-started engine reports isRunning == false, like one stopped by the change
        stt.stopAfterAudioConfigurationChange(of: AVAudioEngine())

        // The error reaches the delegate right after the stop, before anything
        // else (such as a finishing collector) can take over the session
        XCTAssertEqual(stt.stopCount, 1)
        XCTAssertFalse(stt.isListening)
        XCTAssertEqual(delegate.events, ["stopped", "error"])
        let error = try XCTUnwrap(delegate.errors.first)
        guard case RealtimeSTTError.audioError = error else {
            return XCTFail("Unexpected error: \(error)")
        }
    }

    func testChangeIsIgnoredWhenNotListeningOrWithoutEngine() {
        let stt = StubSTT()
        let delegate = RecordingDelegate()
        stt.delegate = delegate

        stt.stopAfterAudioConfigurationChange(of: nil)
        XCTAssertEqual(stt.stopCount, 0)

        stt.isListening = false
        stt.stopAfterAudioConfigurationChange(of: AVAudioEngine())
        XCTAssertEqual(stt.stopCount, 0)
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    // MARK: - AppState accepts only the current session

    func testStoppedSessionDeliversTrailingResultUntilANewOneStarts() {
        let app = AppState(startServices: false)
        let old = StubSTT()
        app.realtimeSTTService = old

        // After a stop, realtimeSTTService is nil and the trailing result is kept
        app.realtimeSTTService = nil
        app.realtimeSTT(old, didReceiveFinalResult: "old trailing")
        XCTAssertEqual(app.currentTranscription, "old trailing")

        // Once a new session runs, the old one cannot overwrite it
        let current = StubSTT()
        app.realtimeSTTService = current
        app.realtimeSTT(current, didReceivePartialResult: "new text")
        app.realtimeSTT(old, didReceiveFinalResult: "old late")
        app.realtimeSTT(old, didReceivePartialResult: "old late")
        XCTAssertEqual(app.currentTranscription, "new text")

        // Nor after the new session is stopped in turn; its own trailing result still counts
        app.realtimeSTTService = nil
        app.realtimeSTT(old, didReceiveFinalResult: "old later")
        XCTAssertEqual(app.currentTranscription, "new text")
        app.realtimeSTT(current, didReceiveFinalResult: "new trailing")
        XCTAssertEqual(app.currentTranscription, "new trailing")
    }

    func testResultsFromAServiceNeverStartedAreIgnored() {
        let app = AppState(startServices: false)
        app.currentTranscription = "kept"
        app.realtimeSTT(StubSTT(), didReceiveFinalResult: "stray")
        XCTAssertEqual(app.currentTranscription, "kept")
    }

    func testOnlyTheCurrentSessionsErrorEndsRecording() {
        let app = AppState(startServices: false)
        let old = StubSTT()
        let current = StubSTT()
        app.realtimeSTTService = current
        app.isRecording = true

        app.realtimeSTT(old, didFailWithError: RealtimeSTTError.audioError("old"))
        XCTAssertTrue(app.isRecording)
        XCTAssertTrue(app.realtimeSTTService === current)

        app.realtimeSTT(current, didFailWithError: RealtimeSTTError.audioError("current"))
        XCTAssertFalse(app.isRecording)
        XCTAssertNil(app.realtimeSTTService)
    }
}
