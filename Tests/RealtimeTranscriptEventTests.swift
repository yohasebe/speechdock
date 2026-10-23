import XCTest
@testable import SpeechDock

/// Records what a realtime STT service reports.
private final class TranscriptRecorder: RealtimeSTTDelegate {
    var partials: [String] = []
    var finals: [String] = []
    func realtimeSTT(_ service: RealtimeSTTService, didReceivePartialResult text: String) { partials.append(text) }
    func realtimeSTT(_ service: RealtimeSTTService, didReceiveFinalResult text: String) { finals.append(text) }
    func realtimeSTT(_ service: RealtimeSTTService, didFailWithError error: Error) {}
    func realtimeSTT(_ service: RealtimeSTTService, didUpdatePreparation message: String?) {}
    func realtimeSTT(_ service: RealtimeSTTService, didChangeListeningState isListening: Bool) {}
}

private func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// Feeds server messages through the real parsers and checks what is shown and kept.
@MainActor
final class RealtimeTranscriptEventTests: XCTestCase {

    // MARK: - Gemini (transcribe model)

    private func gemini() -> (GeminiRealtimeSTT, TranscriptRecorder) {
        let service = GeminiRealtimeSTT()
        let recorder = TranscriptRecorder()
        service.delegate = recorder
        XCTAssertEqual(service.selectedModel, GeminiRealtimeSTT.transcribeModelId)
        return (service, recorder)
    }

    private func final(_ text: String) -> String { json(["serverContent": ["inputTranscription": ["text": text]]]) }
    private func interim(_ text: String) -> String { json(["serverContent": ["interimInputTranscription": ["text": text]]]) }

    func testGeminiInterimTailIsKeptWhenStoppedBeforeItsFinal() {
        let (service, recorder) = gemini()
        service.parseMessage(final("First."))
        service.parseMessage(interim("Second."))
        XCTAssertEqual(recorder.partials.last, "First. Second.")
        service.parseMessage(json(["serverContent": ["turnComplete": true]]))
        service.stopListening()
        XCTAssertEqual(recorder.finals.last, "First. Second.", "text that was shown is not dropped")
    }

    func testGeminiFinalReplacesInterimWithoutDuplication() {
        let (service, recorder) = gemini()
        service.parseMessage(final("First."))
        service.parseMessage(interim("Sec"))
        service.parseMessage(interim("Second"))
        service.parseMessage(final("Second."))
        XCTAssertEqual(recorder.partials.last, "First. Second.")
        service.stopListening()
        XCTAssertEqual(recorder.finals.last, "First. Second.")
    }

    func testGeminiMessageWithFinalAndInterim() {
        let (service, recorder) = gemini()
        service.parseMessage(json(["serverContent": [
            "inputTranscription": ["text": "First."],
            "interimInputTranscription": ["text": "Second"]
        ]]))
        XCTAssertEqual(recorder.partials.last, "First. Second")
    }

    func testGeminiCJKSegmentsHaveNoSpaces() {
        let (service, recorder) = gemini()
        service.parseMessage(final("こんにちは"))
        service.parseMessage(interim("世界"))
        XCTAssertEqual(recorder.partials.last, "こんにちは世界")
        service.parseMessage(final("世界"))
        service.stopListening()
        XCTAssertEqual(recorder.finals.last, "こんにちは世界")
    }

    func testGeminiInterimFromBeforeReconnectIsKept() {
        let (service, recorder) = gemini()
        service.parseMessage(final("First."))
        service.parseMessage(interim("Old tail."))
        service.keepInterimAcrossConnection()  // as on an unexpected disconnection
        service.parseMessage(interim("New session."))
        service.parseMessage(final("New session."))
        service.stopListening()
        XCTAssertEqual(recorder.finals.last, "First. Old tail. New session.")
    }

    func testGeminiTopLevelFinalAlsoReplacesInterim() {
        let (service, recorder) = gemini()
        service.parseMessage(interim("Hello"))
        service.parseMessage(json(["inputTranscription": ["text": "Hello."]]))
        service.stopListening()
        XCTAssertEqual(recorder.finals.last, "Hello.")
    }

    // MARK: - Gemini stop wait

    /// Runs the real stop wait on a fake clock. Each sleep advances the clock and
    /// delivers the events scheduled up to then; returns the time the wait ended.
    private func runStopWait(
        _ service: GeminiRealtimeSTT,
        events: [(at: TimeInterval, apply: () -> Void)]
    ) async -> TimeInterval {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var elapsed: TimeInterval = 0
        var pending = events.sorted { $0.at < $1.at }
        await service.receiveUntilStopGraceEnds(
            generation: service.connectionGeneration,
            now: { start.addingTimeInterval(elapsed) },
            sleep: { nanoseconds in
                elapsed += Double(nanoseconds) / 1e9
                if elapsed > 10 {  // a broken deadline would otherwise spin forever
                    XCTFail("stop wait did not end")
                    service.stopListening()
                }
                while let next = pending.first, next.at <= elapsed {
                    pending.removeFirst()
                    next.apply()
                }
            })
        return elapsed
    }

    func testGeminiStopKeepsFinalArrivingLateInTheGrace() async {
        let (service, recorder) = gemini()
        service.parseMessage(final("First."))
        let stoppedAt = await runStopWait(service, events: [
            (0.05, { service.parseMessage(json(["serverContent": ["turnComplete": true]])) }),
            (0.65, { service.parseMessage(self.final("Second.")) })
        ])
        XCTAssertEqual(recorder.finals, ["First. Second."])
        XCTAssertGreaterThanOrEqual(stoppedAt, GeminiRealtimeSTT.stopGraceInterval, "a quiet period does not end the wait")
    }

    func testGeminiStopEndsAtDeadlineAndKeepsShownTail() async {
        let (service, recorder) = gemini()
        service.parseMessage(final("First."))
        service.parseMessage(interim("Ta"))
        let stoppedAt = await runStopWait(service, events: [
            (0.5, { service.parseMessage(self.interim("Tai")) }),
            (1.4, { service.parseMessage(self.interim("Tail.")) })
        ])
        XCTAssertEqual(recorder.finals, ["First. Tail."])
        XCTAssertGreaterThanOrEqual(stoppedAt, GeminiRealtimeSTT.stopGraceInterval)
        XCTAssertLessThan(stoppedAt, GeminiRealtimeSTT.stopGraceInterval + 0.05, "arriving messages do not extend the wait")
    }

    func testGeminiCancelledStopWaitClosesTheConnection() async {
        let (service, recorder) = gemini()
        service.parseMessage(final("First."))
        let stoppedAt = await runStopWait(service, events: [
            (0.5, { withUnsafeCurrentTask { $0?.cancel() } })
        ])
        XCTAssertEqual(recorder.finals, ["First."])
        XCTAssertLessThan(stoppedAt, 0.6)
    }

    func testGeminiStopWaitDoesNotStopAgainAfterExternalStop() async {
        let (service, recorder) = gemini()
        service.parseMessage(final("First."))
        let stoppedAt = await runStopWait(service, events: [
            (0.5, { service.stopListening() })
        ])
        XCTAssertEqual(recorder.finals, ["First."], "the replaced wait reports nothing more")
        XCTAssertLessThan(stoppedAt, 0.6)
    }

    // MARK: - ElevenLabs

    private func elevenLabs() -> (ElevenLabsRealtimeSTT, TranscriptRecorder) {
        let service = ElevenLabsRealtimeSTT()
        let recorder = TranscriptRecorder()
        service.delegate = recorder
        return (service, recorder)
    }

    private func event(_ type: String, _ text: String) -> String { json(["message_type": type, "text": text]) }

    func testElevenLabsLateTimestampedCopyKeepsNextPartial() {
        let (service, recorder) = elevenLabs()
        service.parseTranscriptionMessage(event("committed_transcript", "First."))
        service.parseTranscriptionMessage(event("partial_transcript", "Second."))
        service.parseTranscriptionMessage(event("committed_transcript_with_timestamps", "First."))
        XCTAssertEqual(recorder.partials.last, "First. Second.", "the late copy does not erase the partial in progress")
    }

    func testElevenLabsRepeatedPhraseIsKept() {
        let (service, recorder) = elevenLabs()
        for _ in 0..<2 {
            service.parseTranscriptionMessage(event("committed_transcript", "はい"))
            service.parseTranscriptionMessage(event("committed_transcript_with_timestamps", "はい"))
        }
        XCTAssertEqual(recorder.partials.last, "はい はい")
    }
}
