import AVFoundation
import Foundation

@MainActor
final class AudioRecordingService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var permissionGranted = false

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    private let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    override init() {
        super.init()
        checkPermission()
    }

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionGranted = true
        case .notDetermined:
            requestPermission()
        case .denied, .restricted:
            permissionGranted = false
        @unknown default:
            permissionGranted = false
        }
    }

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.permissionGranted = granted
            }
        }
    }

    func startRecording() throws {
        guard permissionGranted else {
            throw STTError.microphonePermissionDenied
        }

        let tempDir = FileManager.default.temporaryDirectory
        recordingURL = tempDir.appendingPathComponent("voice_recording_\(UUID().uuidString).m4a")

        guard let url = recordingURL else {
            throw STTError.recordingFailed(NSError(domain: "AudioRecording", code: -1))
        }

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: recordingSettings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            isRecording = true
        } catch {
            throw STTError.recordingFailed(error)
        }
    }

    func stopRecording() -> Data? {
        audioRecorder?.stop()
        isRecording = false

        guard let url = recordingURL else { return nil }

        defer {
            // Clean up temporary file
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        return try? Data(contentsOf: url)
    }

    func cancelRecording() {
        audioRecorder?.stop()
        isRecording = false

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
}

extension AudioRecordingService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.isRecording = false
        }
    }
}
