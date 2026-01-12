import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Delegate protocol for receiving captured audio
protocol SystemAudioCaptureDelegate: AnyObject {
    func systemAudioCapture(_ capture: SystemAudioCaptureService, didCaptureAudioBuffer buffer: AVAudioPCMBuffer)
    func systemAudioCapture(_ capture: SystemAudioCaptureService, didFailWithError error: Error)
}

/// Service for capturing system audio or application-specific audio using ScreenCaptureKit
@MainActor
final class SystemAudioCaptureService: NSObject, ObservableObject {
    static let shared = SystemAudioCaptureService()

    weak var delegate: SystemAudioCaptureDelegate?

    @Published private(set) var isCapturing = false
    @Published private(set) var availableApps: [CapturableApplication] = []

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?

    // Audio format for capture (16kHz mono for STT compatibility)
    private let sampleRate: Double = 16000
    private let channelCount: Int = 1

    private override init() {
        super.init()
    }

    /// Refresh the list of available applications for capture
    func refreshAvailableApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            var apps: [CapturableApplication] = []
            var seenBundleIDs = Set<String>()

            for app in content.applications {
                let bundleID = app.bundleIdentifier
                guard !bundleID.isEmpty,
                      !seenBundleIDs.contains(bundleID) else { continue }

                // Skip system processes and our own app
                if shouldSkipApplication(bundleID: bundleID, name: app.applicationName) {
                    continue
                }
                if bundleID == Bundle.main.bundleIdentifier {
                    continue
                }

                seenBundleIDs.insert(bundleID)

                let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon

                apps.append(CapturableApplication(
                    bundleID: bundleID,
                    name: app.applicationName,
                    icon: icon
                ))
            }

            // Sort by name
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            self.availableApps = apps
        } catch {
            #if DEBUG
            print("Failed to get shareable content: \(error)")
            #endif
        }
    }

    /// Check if an application should be skipped (not shown in the list)
    private func shouldSkipApplication(bundleID: String, name: String) -> Bool {
        // Apple apps that CAN produce audio (should NOT be skipped)
        let appleAudioApps: Set<String> = [
            "com.apple.Safari",
            "com.apple.Music",
            "com.apple.TV",
            "com.apple.Podcasts",
            "com.apple.QuickTimePlayerX",
            "com.apple.iWork.Pages",
            "com.apple.iWork.Keynote",
            "com.apple.iWork.Numbers",
            "com.apple.FaceTime",
            "com.apple.iChat",
            "com.apple.MobileSMS",
            "com.apple.Photos",
            "com.apple.Preview",
            "com.apple.VoiceMemos",
            "com.apple.garageband",
            "com.apple.Logic10",
            "com.apple.FinalCut",
        ]

        // If it's a known Apple audio app, don't skip
        if appleAudioApps.contains(bundleID) {
            return false
        }

        // Skip all other com.apple.* apps (system services, utilities, etc.)
        if bundleID.hasPrefix("com.apple.") {
            return true
        }

        // Skip input methods (works for all languages)
        if bundleID.contains("inputmethod") || bundleID.contains("InputMethod") {
            return true
        }

        // Skip known system service bundle ID patterns
        let systemPatterns = [
            ".accessibility",
            ".Accessibility",
            "loginwindow",
            "ViewService",
            "UIService",
        ]

        for pattern in systemPatterns {
            if bundleID.contains(pattern) {
                return true
            }
        }

        return false
    }

    /// Start capturing system audio
    func startCapturingSystemAudio() async throws {
        guard !isCapturing else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Get the main display for the filter (required even for audio-only capture)
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        // Create filter to capture all audio (exclude no apps)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        try await startCapture(with: filter, captureType: .systemAudio)
    }

    /// Start capturing audio from a specific application
    func startCapturingAppAudio(bundleID: String) async throws {
        guard !isCapturing else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Find the target application
        guard let targetApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw SystemAudioCaptureError.applicationNotFound(bundleID)
        }

        // Get the main display
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        // Create filter to capture only the target app's audio
        let filter = SCContentFilter(display: display, including: [targetApp], exceptingWindows: [])

        try await startCapture(with: filter, captureType: .applicationAudio)
    }

    /// Start capture with the given filter
    private func startCapture(with filter: SCContentFilter, captureType: AudioInputSourceType) async throws {
        let config = SCStreamConfiguration()

        // We only want audio, minimize video capture
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum
        config.showsCursor = false

        // Audio configuration
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = channelCount

        // Exclude our own app's audio to prevent feedback
        config.excludesCurrentProcessAudio = true

        // Create stream
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        // Create and add output handler
        let output = AudioStreamOutput(delegate: self)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

        self.streamOutput = output
        self.stream = stream

        // Start capture
        try await stream.startCapture()
        isCapturing = true

        #if DEBUG
        print("SystemAudioCapture: Started capturing \(captureType.rawValue)")
        #endif
    }

    /// Stop capturing
    func stopCapturing() async {
        guard isCapturing, let stream = stream else { return }

        do {
            try await stream.stopCapture()
        } catch {
            #if DEBUG
            print("SystemAudioCapture: Error stopping capture: \(error)")
            #endif
        }

        self.stream = nil
        self.streamOutput = nil
        isCapturing = false

        #if DEBUG
        print("SystemAudioCapture: Stopped capturing")
        #endif
    }
}

// MARK: - Audio Stream Output

private class AudioStreamOutput: NSObject, SCStreamOutput {
    weak var delegate: SystemAudioCaptureService?

    init(delegate: SystemAudioCaptureService) {
        self.delegate = delegate
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let audioBuffer = convertToAudioPCMBuffer(sampleBuffer) else {
            return
        }

        // Notify delegate on main thread
        Task { @MainActor in
            self.delegate?.delegate?.systemAudioCapture(self.delegate!, didCaptureAudioBuffer: audioBuffer)
        }
    }

    private func convertToAudioPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        guard let audioFormat = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Get audio buffer list
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return nil
        }

        // Copy data to PCM buffer
        if let srcData = audioBufferList.mBuffers.mData,
           let dstData = pcmBuffer.floatChannelData?[0] {
            let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
            memcpy(dstData, srcData, byteCount)
        }

        return pcmBuffer
    }
}

// MARK: - Errors

enum SystemAudioCaptureError: LocalizedError {
    case noDisplayAvailable
    case applicationNotFound(String)
    case captureNotSupported

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for capture"
        case .applicationNotFound(let bundleID):
            return "Application not found: \(bundleID)"
        case .captureNotSupported:
            return "Audio capture is not supported on this system"
        }
    }
}
