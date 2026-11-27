import AVFoundation
import XCTest
@testable import SpeechDock

@MainActor
final class StreamingAudioPlayerTests: XCTestCase {
    func testPlaybackEndsWhenAReconfigurationStopsTheEngine() async throws {
        let player = StreamingAudioPlayer()
        var reported: Error?
        player.onError = { reported = $0 }
        do { try player.startStreaming() } catch {
            throw XCTSkip("No audio output available: \(error)")
        }
        let engine = try XCTUnwrap(player.audioEngine)

        engine.stop()  // what an output device change can do
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(player.state, .idle)
        XCTAssertNotNil(reported)
    }

    func testPlaybackContinuesWhenTheEngineKeepsRunning() async throws {
        let player = StreamingAudioPlayer()
        var reported: Error?
        player.onError = { reported = $0 }
        do { try player.startStreaming() } catch {
            throw XCTSkip("No audio output available: \(error)")
        }
        defer { player.stop() }
        let engine = try XCTUnwrap(player.audioEngine)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(player.state, .playing)
        XCTAssertNil(reported)
    }

    func testStoppedEngineEndsPlaybackAsInterruptedNotFinished() async throws {
        let player = StreamingAudioPlayer()
        var reported: Error?
        var finished = 0
        player.onError = { reported = $0 }
        player.onPlaybackFinished = { _ in finished += 1 }
        do { try player.startStreaming() } catch {
            throw XCTSkip("No audio output available: \(error)")
        }
        let engine = try XCTUnwrap(player.audioEngine)
        player.appendData(Data(count: 48_000))  // one second of silence, 24 kHz Int16
        player.finishStream()

        // Stopping the engine can complete the queued buffers right away.
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(player.state, .idle)
        XCTAssertNotNil(reported)
        XCTAssertEqual(finished, 0, "an interruption is not reported as a normal finish")
    }

    func testResumeAfterTheEngineStoppedWhilePausedEndsPlayback() throws {
        let player = StreamingAudioPlayer()
        var reported: Error?
        player.onError = { reported = $0 }
        do { try player.startStreaming() } catch {
            throw XCTSkip("No audio output available: \(error)")
        }
        player.pause()
        player.audioEngine?.stop()
        player.resume()

        XCTAssertEqual(player.state, .idle)
        XCTAssertNotNil(reported)
    }
}
