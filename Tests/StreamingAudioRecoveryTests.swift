import XCTest
@testable import SpeechDock

@MainActor
final class StreamingAudioRecoveryTests: XCTestCase {

    /// A device change or Bluetooth wake-up can stop the engine mid-stream. The queued audio
    /// used to be lost and playback never reported finishing, which froze Live OCR speech.
    func testPlaybackFinishesAfterEngineStopsMidStream() async throws {
        let player = StreamingAudioPlayer(preRollSeconds: 0.08)
        let finished = expectation(description: "finished")
        player.onPlaybackFinished = { _ in finished.fulfill() }
        do { try player.startStreaming() } catch { throw XCTSkip("No audio output available: \(error)") }

        let silence = Data(count: 48_000 * 3 / 2)  // 1.5 s of 24 kHz 16-bit silence
        stride(from: 0, to: silence.count, by: 4800).forEach {
            player.appendData(silence.subdata(in: $0..<min($0 + 4800, silence.count)))
        }
        let start = Date()
        player.finishStream()

        try await Task.sleep(for: .milliseconds(300))
        player.simulateEngineInterruption()

        await fulfillment(of: [finished], timeout: 5)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 1.3, "the requeued audio played to the end")
    }
}
