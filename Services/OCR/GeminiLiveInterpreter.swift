import Foundation
import os

private let liveLog = Logger(subsystem: "com.speechdock.app", category: "LiveOCR")

/// Streamed PCM output the interpreter plays into (StreamingAudioPlayer in the app).
@MainActor
protocol LiveAudioOutput: AnyObject {
    var onPlaybackStarted: (() -> Void)? { get set }
    var onPlaybackFinished: ((Bool) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var outputDeviceUID: String { get set }
    func startStreaming() throws
    func appendData(_ data: Data)
    func finishStream()
    func stop()
    func setPlaybackRate(_ rate: Float)
}

extension StreamingAudioPlayer: LiveAudioOutput {}

/// Speaks subtitle lines in another language through one Gemini Live session.
///
/// Each line goes out as text and comes back as streamed speech in the target
/// language, so translation and synthesis are a single round trip and playback
/// starts while audio is still arriving. The session keeps earlier lines as
/// context, which keeps names and tone consistent.
///
/// Latency: the session connects as soon as the interpreter is prepared, and the
/// next line is sent as soon as the current reply has finished *generating*
/// (not playing); its audio is held and played right after the current line.
/// A new turn would interrupt a reply still being generated, so at most one
/// line is in generation and one is held; newer waiting lines replace older ones.
@MainActor
final class GeminiLiveInterpreter {
    struct Configuration: Equatable {
        var model = GeminiLiveInterpreter.defaultModel
        var voice: String
        var sourceLanguage: String
        var targetLanguage: String
        var speed: Double
        var outputDeviceUID: String
    }

    /// Fastest Live voice model measured: ~0.5 s median to first audio
    /// (gemini-3.1-flash-live-preview: ~0.6 s).
    static let defaultModel = "gemini-3.8-live"
    /// Speed-up while newer lines wait, so speech catches up with the video.
    static let catchUpFactor = 1.25
    /// A reply not complete after this is abandoned and the session reopened.
    private let maxGeneration: Duration
    /// Grace after a line's audio should have ended before playback is cut.
    private let playbackGrace: Duration
    private static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    let configuration: Configuration
    /// The translation of a source line, as it arrives: (source line, translation so far).
    /// Sent as soon as Gemini produces it, before that line's audio is played.
    var onTranscript: ((String, String) -> Void)?
    /// Reports a failure, or nil once speech works again.
    var onError: ((String?) -> Void)?
    /// Whether a line is currently being spoken.
    var onSpeakingChanged: ((Bool) -> Void)?

    private let apiKeyManager = APIKeyManager.shared
    private let audio: LiveAudioOutput
    /// Replaces the network in tests: receives each line instead of the socket.
    private let sendOverride: ((String) async throws -> Void)?

    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connecting: Task<Void, Error>?
    private var setupWaiter: CheckedContinuation<Void, Error>?
    private var isSetupComplete = false

    // Turn pipeline
    private struct HeldTurn {
        let id: Int
        var audio = Data()
        var complete = false
    }
    private var waiting: String?
    private var lastQueued = ""
    private var turnCounter = 0
    private var generatingTurn: Int?   // Sent; reply still arriving
    private var playingTurn: Int?      // Its audio is in the player
    private var heldTurn: HeldTurn?    // Arriving while another line plays
    private var transcripts: [Int: String] = [:]
    private var sourceLines: [Int: String] = [:]

    // Watchdogs: a turn must never wait forever, or every later line queues behind it.
    private var generationWatchdog: Task<Void, Never>?
    private var playbackWatchdog: Task<Void, Never>?
    private var playingBytes = 0

    init(configuration: Configuration,
         audio: LiveAudioOutput? = nil,
         sendOverride: ((String) async throws -> Void)? = nil,
         maxGeneration: Duration = .seconds(10),
         playbackGrace: Duration = .seconds(2)) {
        self.configuration = configuration
        self.maxGeneration = maxGeneration
        self.playbackGrace = playbackGrace
        // Live audio arrives faster than real time, so a short pre-roll is enough.
        self.audio = audio ?? StreamingAudioPlayer(preRollSeconds: 0.08)
        self.sendOverride = sendOverride
        self.audio.outputDeviceUID = configuration.outputDeviceUID
        self.audio.onPlaybackStarted = { [weak self] in
            self?.onError?(nil)
            self?.onSpeakingChanged?(true)
        }
        self.audio.onPlaybackFinished = { [weak self] _ in self?.playbackFinished() }
        self.audio.onError = { [weak self] error in
            self?.onError?(error.localizedDescription)
            self?.playbackFinished()
        }
    }

    /// Opens the session ahead of the first line so it doesn't wait for setup.
    func prepare() {
        guard sendOverride == nil else { return }
        Task { [weak self] in
            do { try await self?.ensureConnected() } catch {
                guard let self else { return }
                self.onError?(Self.describe(error, socket: self.socket))
                self.disconnect()
            }
        }
    }

    func enqueue(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line != lastQueued else { return }
        lastQueued = line
        waiting = line
        sendNextIfPossible()
        updatePlaybackRate()
    }

    func stop() {
        generationWatchdog?.cancel()
        playbackWatchdog?.cancel()
        waiting = nil
        generatingTurn = nil
        playingTurn = nil
        heldTurn = nil
        transcripts.removeAll()
        sourceLines.removeAll()
        audio.stop()
        disconnect()
    }

    // MARK: - Turn pipeline

    private func sendNextIfPossible() {
        guard generatingTurn == nil, heldTurn == nil, let line = waiting else { return }
        waiting = nil
        turnCounter += 1
        let turn = turnCounter
        generatingTurn = turn
        transcripts[turn] = ""
        sourceLines[turn] = line
        liveLog.info("turn \(turn) sent (\(line.count) chars)")
        armGenerationWatchdog(for: turn)
        Task { [weak self] in
            guard let self else { return }
            do {
                if let sendOverride = self.sendOverride {
                    try await sendOverride(line)
                } else {
                    try await self.ensureConnected()
                    try await self.send([
                        "clientContent": [
                            "turns": [["role": "user", "parts": [["text": line]]]],
                            "turnComplete": true
                        ]
                    ])
                }
            } catch {
                self.onError?(Self.describe(error, socket: self.socket))
                self.disconnect()
                // Give up on this line; the next one retries rather than looping here.
                self.turnFinishedGenerating(turn)
            }
        }
    }

    private func receivedAudio(_ data: Data) {
        guard let turn = generatingTurn else { return }
        if playingTurn == turn {
            playingBytes += data.count
            audio.appendData(data)
        } else if playingTurn == nil {
            startPlaying(turn, initial: data, complete: false)
        } else {
            if heldTurn == nil {
                heldTurn = HeldTurn(id: turn)
                updatePlaybackRate()
            }
            heldTurn?.audio.append(data)
        }
    }

    private func receivedTranscript(_ text: String) {
        guard let turn = generatingTurn else { return }
        transcripts[turn, default: ""] += text
        publishTranscript(of: turn)
    }

    /// The reply for `turn` is complete (or was cut off / failed).
    private func turnFinishedGenerating(_ turn: Int) {
        guard generatingTurn == turn else { return }
        generationWatchdog?.cancel()
        generatingTurn = nil
        liveLog.info("turn \(turn) generated")
        if playingTurn == turn {
            audio.finishStream()
            armPlaybackWatchdog(for: turn)
        } else if heldTurn?.id == turn {
            heldTurn?.complete = true
        } else {
            forget(turn)  // Nothing to play.
        }
        sendNextIfPossible()
    }

    private func playbackFinished() {
        guard let finished = playingTurn else { return }
        playbackWatchdog?.cancel()
        playingTurn = nil
        liveLog.info("turn \(finished) played")
        forget(finished)
        if let held = heldTurn {
            heldTurn = nil
            startPlaying(held.id, initial: held.audio, complete: held.complete)
        } else {
            onSpeakingChanged?(false)
        }
        sendNextIfPossible()
    }

    private func startPlaying(_ turn: Int, initial: Data, complete: Bool) {
        do {
            try audio.startStreaming()
        } catch {
            onError?(error.localizedDescription)
            forget(turn)
            if generatingTurn == turn { generatingTurn = nil }  // Drop it; its later audio is ignored.
            onSpeakingChanged?(false)
            sendNextIfPossible()
            return
        }
        playingTurn = turn
        playingBytes = initial.count
        updatePlaybackRate()
        if !initial.isEmpty { audio.appendData(initial) }
        if complete {
            audio.finishStream()
            armPlaybackWatchdog(for: turn)
        }
    }

    private func armGenerationWatchdog(for turn: Int) {
        generationWatchdog?.cancel()
        generationWatchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.maxGeneration ?? .seconds(10))
            guard !Task.isCancelled, let self, self.generatingTurn == turn else { return }
            liveLog.error("turn \(turn): no reply within the limit; reopening the session")
            self.onError?("Gemini Live did not answer in time; reconnecting")
            self.disconnect()
            self.turnFinishedGenerating(turn)
        }
    }

    /// Called once a line's audio is complete: if playback hasn't reported the end by the
    /// time it should have (plus a grace period), cut it so the next line can play.
    private func armPlaybackWatchdog(for turn: Int) {
        playbackWatchdog?.cancel()
        let rate = max(0.25, configuration.speed)
        let seconds = Double(playingBytes) / 48_000 / rate  // 24 kHz, 16-bit mono
        let grace = playbackGrace
        playbackWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)) + grace)
            guard !Task.isCancelled, let self, self.playingTurn == turn else { return }
            liveLog.error("turn \(turn): playback did not report its end; moving on")
            self.audio.stop()
            self.playbackFinished()
        }
    }

    /// Normal speed, or faster while a newer line is already waiting behind this one.
    private func updatePlaybackRate() {
        guard let playing = playingTurn else { return }
        let behind = heldTurn != nil || waiting != nil || (generatingTurn.map { $0 != playing } ?? false)
        audio.setPlaybackRate(Float(min(4, configuration.speed * (behind ? Self.catchUpFactor : 1))))
    }

    private func publishTranscript(of turn: Int) {
        let text = (transcripts[turn] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let line = sourceLines[turn] else { return }
        onTranscript?(line, text)
    }

    private func forget(_ turn: Int) {
        transcripts[turn] = nil
        sourceLines[turn] = nil
    }

    // MARK: - Server messages

    /// Handles one server message. Internal so tests can feed recorded messages.
    func handleServerMessage(_ json: [String: Any]) {
        if json["setupComplete"] != nil {
            isSetupComplete = true
            setupWaiter?.resume()
            setupWaiter = nil
            return
        }
        if json["goAway"] != nil {
            // This connection closes soon. Let the current reply finish on it and
            // open the next one now, so the next line doesn't wait for setup.
            socket = nil
            prepare()
            return
        }
        guard let content = json["serverContent"] as? [String: Any] else { return }

        if let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any],
                      let base64 = inline["data"] as? String,
                      let data = Data(base64Encoded: base64) else { continue }
                receivedAudio(data)
            }
        }
        if let text = (content["outputTranscription"] as? [String: Any])?["text"] as? String {
            receivedTranscript(text)
        }
        if content["turnComplete"] as? Bool == true || content["interrupted"] as? Bool == true,
           let turn = generatingTurn {
            turnFinishedGenerating(turn)
        }
    }

    // MARK: - Connection

    private func ensureConnected() async throws {
        if socket != nil, connecting == nil { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await connect() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func connect() async throws {
        guard let apiKey = await apiKeyManager.apiKey(for: .gemini) else {
            throw TTSError.apiError(apiKeyManager.unavailableReason(for: .gemini))
        }
        guard let url = URL(string: Self.endpoint) else { throw TTSError.apiError("Invalid Gemini Live URL") }
        var request = URLRequest(url: url)
        // Header rather than ?key= so the key never appears in a logged URL.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: request)
        urlSession = session
        self.socket = socket
        isSetupComplete = false
        socket.resume()
        startReceiving(on: socket)

        try await send(setupMessage())
        guard !isSetupComplete else { return }  // Arrived while the send was in flight.
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, let waiter = self.setupWaiter else { return }
            self.setupWaiter = nil
            waiter.resume(throwing: TTSError.networkError("Gemini Live did not respond to setup"))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { setupWaiter = $0 }
    }

    private func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
        setupWaiter?.resume(throwing: CancellationError())
        setupWaiter = nil
    }

    private func setupMessage() -> [String: Any] {
        let config = configuration
        let instruction = """
            You are a live dubbing interpreter for a video. Every user message is one on-screen \
            subtitle line in \(config.sourceLanguage). Respond only by speaking its translation in \
            \(config.targetLanguage), naturally and concisely, in the speaker's tone. Never add \
            greetings, explanations, questions or anything that is not in the line. Keep names \
            consistent with earlier lines.
            """
        return [
            "setup": [
                "model": "models/\(config.model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": config.voice]]
                    ]
                ],
                "systemInstruction": ["parts": [["text": instruction]]],
                "outputAudioTranscription": [String: Any](),
                // Keeps long videos within the context window instead of ending the session.
                "contextWindowCompression": ["slidingWindow": [String: Any]()]
            ]
        ]
    }

    private func send(_ message: [String: Any]) async throws {
        guard let socket else { throw TTSError.networkError("Gemini Live is not connected") }
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func startReceiving(on socket: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    self?.handleServerMessage(json)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.connectionLost(socket, reason: Self.describe(error, socket: socket))
                    return
                }
            }
        }
    }

    private func connectionLost(_ lost: URLSessionWebSocketTask, reason: String) {
        if let waiter = setupWaiter {
            setupWaiter = nil
            waiter.resume(throwing: TTSError.networkError(reason))  // Reported by whoever is connecting.
        }
        if socket === lost { disconnect() }
        // An idle session closing is normal; the next line reconnects. Only a cut-off reply is an error.
        guard let turn = generatingTurn else { return }
        onError?(reason)
        turnFinishedGenerating(turn)
    }

    private static func describe(_ error: Error, socket: URLSessionWebSocketTask?) -> String {
        if let reasonData = socket?.closeReason, let reason = String(data: reasonData, encoding: .utf8), !reason.isEmpty {
            return "Gemini Live: \(reason)"
        }
        return error.localizedDescription
    }
}
