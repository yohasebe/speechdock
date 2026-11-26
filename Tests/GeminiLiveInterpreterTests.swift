import XCTest
@testable import SpeechDock

@MainActor
final class GeminiLiveInterpreterTests: XCTestCase {
    private var sent: [String] = []
    private var audio: FakeLiveAudio!
    private var transcripts: [String] = []
    private var transcriptLines: [String] = []

    private func makeInterpreter(maxGeneration: Duration = .seconds(10),
                                 playbackGrace: Duration = .seconds(2)) -> GeminiLiveInterpreter {
        sent = []
        transcripts = []
        transcriptLines = []
        audio = FakeLiveAudio()
        let interpreter = GeminiLiveInterpreter(
            configuration: .init(voice: "Zephyr", sourceLanguage: "English", targetLanguage: "Vietnamese",
                                 speed: 1, outputDeviceUID: ""),
            audio: audio,
            sendOverride: { [unowned self] line in self.sent.append(line) },
            maxGeneration: maxGeneration,
            playbackGrace: playbackGrace
        )
        interpreter.onTranscript = { [unowned self] line, text in
            self.transcriptLines.append(line)
            self.transcripts.append(text)
        }
        return interpreter
    }

    func testNextLineIsSentOnceCurrentReplyIsGeneratedAndPlaysAfterIt() async {
        let interpreter = makeInterpreter()
        interpreter.enqueue("one")
        await settle()
        XCTAssertEqual(sent, ["one"])

        interpreter.handleServerMessage(audioMessage([1, 1]))
        interpreter.handleServerMessage(transcriptMessage("một"))
        interpreter.handleServerMessage(turnComplete)
        XCTAssertEqual(audio.streams, 1)
        XCTAssertEqual(audio.finishedStreams, 1)
        XCTAssertEqual(transcripts.last, "một")

        // Line one is still playing; line two goes out now instead of after playback.
        interpreter.enqueue("two")
        await settle()
        XCTAssertEqual(sent, ["one", "two"])
        interpreter.handleServerMessage(audioMessage([2, 2]))
        interpreter.handleServerMessage(transcriptMessage("hai"))
        interpreter.handleServerMessage(turnComplete)
        XCTAssertEqual(audio.appended, [Data([1, 1])], "held until line one finishes playing")
        XCTAssertEqual(transcripts.last, "hai", "a translation is shown as soon as it arrives, not when spoken")
        XCTAssertEqual(transcriptLines.last, "two", "tagged with its source line so stale ones can be dropped")

        XCTAssertEqual(audio.rates.last, Float(GeminiLiveInterpreter.catchUpFactor),
                       "line one speeds up while line two waits behind it")

        audio.finishPlayback()
        XCTAssertEqual(audio.rates.last, 1, "nothing waiting behind line two: normal speed")
        XCTAssertEqual(audio.streams, 2)
        XCTAssertEqual(audio.appended, [Data([1, 1]), Data([2, 2])])
        XCTAssertEqual(audio.finishedStreams, 2)
        XCTAssertEqual(transcripts.last, "hai")
    }

    func testLinesArrivingDuringGenerationKeepOnlyTheNewest() async {
        let interpreter = makeInterpreter()
        interpreter.enqueue("one")
        await settle()
        interpreter.enqueue("two")
        interpreter.enqueue("three")
        await settle()
        XCTAssertEqual(sent, ["one"], "a new turn would interrupt the reply being generated")

        interpreter.handleServerMessage(turnComplete)
        await settle()
        XCTAssertEqual(sent, ["one", "three"])
    }

    func testRepeatedLineIsNotSentTwice() async {
        let interpreter = makeInterpreter()
        interpreter.enqueue("same")
        await settle()
        interpreter.handleServerMessage(turnComplete)
        interpreter.enqueue("same")
        await settle()
        XCTAssertEqual(sent, ["same"])
    }

    func testReplyThatNeverCompletesDoesNotBlockLaterLines() async throws {
        let interpreter = makeInterpreter(maxGeneration: .milliseconds(50))
        interpreter.enqueue("one")
        await settle()
        interpreter.enqueue("two")  // Waits: "one" is still generating and never completes.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sent, ["one", "two"], "the stalled reply is abandoned and the next line goes out")
    }

    func testPlaybackThatNeverReportsItsEndDoesNotBlockLaterLines() async throws {
        let interpreter = makeInterpreter(playbackGrace: .milliseconds(50))
        interpreter.enqueue("one")
        await settle()
        interpreter.handleServerMessage(audioMessage([1, 1]))
        interpreter.handleServerMessage(turnComplete)
        interpreter.enqueue("two")
        await settle()
        interpreter.handleServerMessage(audioMessage([2, 2]))
        interpreter.handleServerMessage(turnComplete)
        XCTAssertEqual(audio.streams, 1, "line two is held behind line one")
        // The fake player never calls onPlaybackFinished, like an engine stopped by a device change.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(audio.streams, 2, "line one is cut and line two plays")
        XCTAssertEqual(audio.appended.last, Data([2, 2]))
    }

    // MARK: - Helpers

    private let turnComplete: [String: Any] = ["serverContent": ["turnComplete": true]]

    private func audioMessage(_ bytes: [UInt8]) -> [String: Any] {
        ["serverContent": ["modelTurn": ["parts": [["inlineData": [
            "mimeType": "audio/pcm;rate=24000", "data": Data(bytes).base64EncodedString()
        ]]]]]]
    }

    private func transcriptMessage(_ text: String) -> [String: Any] {
        ["serverContent": ["outputTranscription": ["text": text]]]
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private final class FakeLiveAudio: LiveAudioOutput {
    var onPlaybackStarted: (() -> Void)?
    var onPlaybackFinished: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var outputDeviceUID = ""
    private(set) var streams = 0
    private(set) var finishedStreams = 0
    private(set) var appended: [Data] = []
    private(set) var rates: [Float] = []

    func startStreaming() throws { streams += 1 }
    func appendData(_ data: Data) {
        appended.append(data)
        if appended.count == 1 { onPlaybackStarted?() }
    }
    func finishStream() { finishedStreams += 1 }
    func stop() {}
    func setPlaybackRate(_ rate: Float) { rates.append(rate) }
    func finishPlayback() { onPlaybackFinished?(true) }
}
