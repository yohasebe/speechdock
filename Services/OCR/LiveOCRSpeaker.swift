import Foundation

/// Which voice reads live subtitles.
enum LiveOCRVoice: String, CaseIterable, Identifiable {
    /// The provider, voice and model chosen under Text-to-Speech
    case textToSpeech
    /// The built-in macOS voice: instant and offline
    case macOS
    /// Gemini Live translates and speaks in one streamed step
    case geminiLive

    var id: String { rawValue }
}

/// Reads live subtitle lines aloud, one at a time.
///
/// A line is never cut off mid-sentence. While one is playing, only the newest
/// incoming line is kept; older unread ones are dropped, so speech stays close
/// to what is on screen instead of drifting further behind the video.
///
/// With a provider that can fetch audio ahead (`PresynthesizingTTSService`),
/// the waiting line's audio is requested as soon as the line arrives, so the
/// network round trip overlaps the line that is playing instead of following it.
@MainActor
final class LiveOCRSpeaker: TTSDelegate {
    private struct Line {
        let id = UUID()
        let text: String
        let audio: Task<PreparedSpeech, Error>?
    }

    private let makeService: () -> TTSService
    private lazy var service: TTSService = {
        let service = makeService()
        service.delegate = self
        return service
    }()
    private var waiting: Line?
    private var playing: UUID?
    private var lastQueued = ""
    /// Reports a speech failure, or nil once speech works again.
    var onError: ((String?) -> Void)?
    /// Whether a line is currently being spoken.
    var onSpeakingChanged: ((Bool) -> Void)?

    var isSpeaking: Bool { playing != nil }

    init(makeService: @escaping () -> TTSService) {
        self.makeService = makeService
    }

    func enqueue(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line != lastQueued else { return }
        lastQueued = line
        let spoken = TextReplacementService.shared.applyReplacements(to: line)
        let audio: Task<PreparedSpeech, Error>?
        if let prefetching = service as? PresynthesizingTTSService {
            audio = Task { try await prefetching.synthesize(text: spoken) }
        } else {
            audio = nil
        }
        waiting?.audio?.cancel()  // Superseded before it was spoken.
        waiting = Line(text: spoken, audio: audio)
        playNextIfIdle()
        if waiting != nil {
            // A newer line is waiting: finish this one faster so speech catches up.
            // The next line starts at normal speed again.
            service.setPlaybackRate(Float(min(4, service.selectedSpeed * GeminiLiveInterpreter.catchUpFactor)))
        }
    }

    func stop() {
        waiting?.audio?.cancel()
        waiting = nil
        playing = nil
        service.delegate = nil
        service.stop()
    }

    private func playNextIfIdle() {
        guard playing == nil, let line = waiting else { return }
        waiting = nil
        playing = line.id
        let service = self.service
        Task { [weak self] in
            do {
                if let audio = line.audio, let prefetching = service as? PresynthesizingTTSService {
                    let speech = try await audio.value
                    guard self?.playing == line.id else { return }
                    try prefetching.play(speech)
                } else {
                    try await service.speak(text: line.text)
                }
            } catch is CancellationError {
                self?.finish(line.id)
            } catch {
                guard let self, self.playing == line.id else { return }
                self.onError?(error.localizedDescription)
                self.finish(line.id)
            }
        }
    }

    private func finish(_ id: UUID) {
        guard playing == id else { return }
        playing = nil
        playNextIfIdle()
        if playing == nil { onSpeakingChanged?(false) }
    }

    // MARK: - TTSDelegate

    func tts(_ service: TTSService, willSpeakRange range: NSRange, of text: String) {}

    func ttsDidStartSpeaking(_ service: TTSService) {
        onError?(nil)
        onSpeakingChanged?(true)
    }

    func tts(_ service: TTSService, didFinishSpeaking successfully: Bool) {
        if let playing { finish(playing) }
    }

    func tts(_ service: TTSService, didFailWithError error: Error) {
        onError?(error.localizedDescription)
        if let playing { finish(playing) }
    }
}
