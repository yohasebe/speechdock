import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Continuously watches one screen region and reports its text as it changes.
///
/// Built for on-screen subtitles (e.g. a streaming player's caption area): the
/// region is captured every `interval`, re-recognized only when its pixels
/// change, and a new text is reported only once it has been read the same way
/// on consecutive passes, so fade-in frames and OCR jitter don't flicker.
/// While a new line awaits that second read, the next capture comes after
/// `confirmDelay` instead of a full interval, which keeps reporting fast.
/// SpeechDock's own windows are excluded from the capture, so the subtitle
/// overlay may sit on top of the watched region.
@MainActor
final class LiveOCRSession {
    /// Called with the new stable text ("" when the region no longer shows text).
    var onTextChanged: ((String) -> Void)?
    /// Called once if capturing fails for good (e.g. the display went away).
    var onFailure: ((Error) -> Void)?

    let region: CGRect
    private let interval: Duration
    /// Gap before the confirming read of a new line (well under one interval).
    private static let confirmDelay: Duration = .milliseconds(50)
    private let languages: [String]
    private var stabilizer = LiveOCRStabilizer()
    private var loopTask: Task<Void, Never>?
    private var outline: RegionOutlineWindow?

    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var lastFingerprint: [UInt8]?
    private var lastRawText = ""
    private var lastRecognition = ContinuousClock.now
    /// Re-read at least this often even if the frame looks unchanged (safety net for the
    /// change check; a pass costs ~35 ms).
    private static let maxSkip: Duration = .seconds(1)
    private var consecutiveFailures = 0

    init(region: CGRect, interval: TimeInterval, languages: [String]) {
        self.region = region.integral
        self.interval = .milliseconds(Int(max(0.1, interval) * 1000))
        self.languages = languages
    }

    func start() {
        guard loopTask == nil else { return }
        outline = RegionOutlineWindow(region: region)
        outline?.orderFrontRegardless()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                let started = ContinuousClock.now
                guard let self else { return }
                await self.tick()
                let delay = self.stabilizer.isConfirming ? min(Self.confirmDelay, self.interval) : self.interval
                try? await Task.sleep(until: started + delay, clock: .continuous)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        outline?.orderOut(nil)
        outline = nil
    }

    // MARK: - Loop

    private func tick() async {
        do {
            let image = try await captureFrame()
            consecutiveFailures = 0
            let fingerprint = Self.fingerprint(of: image)
            if let last = lastFingerprint, let fingerprint, Self.isSameFrame(last, fingerprint),
               ContinuousClock.now - lastRecognition < Self.maxSkip {
                // Nothing moved: count it as another identical read without re-running OCR.
                emit(stabilizer.ingest(lastRawText))
                return
            }
            lastFingerprint = fingerprint
            lastRecognition = .now
            let text: String
            do {
                text = try await OCRService.recognizeText(from: image, languages: languages,
                                                          accuracy: .accurate, minimumConfidence: 0.3)
            } catch OCRService.OCRError.noTextFound {
                text = ""
            }
            guard !Task.isCancelled else { return }
            lastRawText = text
            emit(stabilizer.ingest(text))
        } catch is CancellationError {
            return
        } catch {
            consecutiveFailures += 1
            filter = nil  // Rebuild the filter: displays or windows may have changed.
            dprint("LiveOCR: capture failed (\(consecutiveFailures)): \(error.localizedDescription)")
            if consecutiveFailures >= 5 {
                stop()
                onFailure?(error)
            }
        }
    }

    private func emit(_ text: String?) {
        guard let text, !Task.isCancelled else { return }
        onTextChanged?(text)
    }

    // MARK: - Capture

    private func captureFrame() async throws -> CGImage {
        if filter == nil { try await prepareCapture() }
        guard let filter, let configuration else { throw ScreenCaptureService.CaptureError.captureFailed }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Builds the display filter once; a screenshot per tick then costs only the capture itself.
    private func prepareCapture() async throws {
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw ScreenCaptureService.CaptureError.noScreensAvailable }

        let clipped = screen.frame.intersection(region)
        guard !clipped.isNull, clipped.width >= 4, clipped.height >= 4 else {
            throw ScreenCaptureService.CaptureError.invalidRect
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureService.CaptureError.noScreensAvailable
        }
        // Exclude all of SpeechDock (subtitle overlay, outline, panels) so it never reads itself.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = ScreenCaptureService.sourceRect(clipped, on: screen.frame)
        // Point resolution: subtitle-sized text reads as well as at 2x (measured
        // ~33 ms vs ~37 ms per pass, with fewer misreads), with a quarter of the pixels.
        config.width = Int(ceil(clipped.width))
        config.height = Int(ceil(clipped.height))
        config.showsCursor = false

        self.filter = filter
        self.configuration = config
    }

    // MARK: - Change detection

    /// Large enough that one changed word in a wide subtitle strip changes several pixels.
    private static let fingerprintSize = (width: 128, height: 32)

    /// A tiny grayscale thumbnail; comparing two of them is far cheaper than OCR.
    nonisolated static func fingerprint(of image: CGImage) -> [UInt8]? {
        let (width, height) = fingerprintSize
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Unchanged unless some pixels moved noticeably. Counting changed pixels, rather than
    /// averaging, keeps a small text change from being diluted by a large static background.
    nonisolated static func isSameFrame(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var changed = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 24 {
            changed += 1
            if changed > 2 { return false }  // A stray pixel or two is capture noise.
        }
        return true
    }
}

// MARK: - Stabilizer

/// Turns a stream of raw OCR reads into stable text changes.
struct LiveOCRStabilizer {
    /// Consecutive matching reads needed before a new text is reported.
    var requiredReads = 2
    /// Consecutive empty reads needed before the text is cleared.
    var clearAfterEmptyReads = 3

    private(set) var committed = ""
    /// A new line has been read once and is waiting for its confirming read.
    var isConfirming: Bool { candidateReads > 0 }
    private var candidate = ""
    private var candidateReads = 0
    private var emptyReads = 0

    /// Returns the new committed text when it changes, otherwise nil.
    mutating func ingest(_ raw: String) -> String? {
        let text = Self.normalize(raw)
        guard !text.isEmpty else {
            candidate = ""
            candidateReads = 0
            emptyReads += 1
            if !committed.isEmpty && emptyReads >= clearAfterEmptyReads {
                committed = ""
                return ""
            }
            return nil
        }
        emptyReads = 0
        if Self.isSimilar(text, committed) {
            candidate = ""
            candidateReads = 0
            return nil
        }
        candidateReads = Self.isSimilar(text, candidate) ? candidateReads + 1 : 1
        candidate = text
        guard candidateReads >= requiredReads else { return nil }
        committed = candidate
        candidate = ""
        candidateReads = 0
        return committed
    }

    /// Trims each line and collapses runs of spaces.
    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Same subtitle read twice with OCR noise (a few characters off) counts as equal.
    static func isSimilar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let tolerance = max(1, max(a.count, b.count) / 12)
        guard abs(a.count - b.count) <= tolerance else { return false }
        return editDistance(Array(a.lowercased()), Array(b.lowercased())) <= tolerance
    }

    /// Levenshtein distance; both inputs are non-empty (checked by the caller).
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

// MARK: - Region outline

/// Click-through dashed frame showing which region is being watched.
private final class RegionOutlineWindow: NSWindow {
    private static let inset: CGFloat = -4

    init(region: CGRect) {
        super.init(contentRect: region.insetBy(dx: Self.inset, dy: Self.inset),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        level = .floating
        collectionBehavior = ToolWindowPolicy.currentSpace
        isReleasedWhenClosed = false
        contentView = OutlineView()
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemOrange.withAlphaComponent(0.8).setStroke()
            path.stroke()
        }
    }
}
