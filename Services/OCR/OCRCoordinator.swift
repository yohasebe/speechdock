import Foundation
import AppKit
import Combine

/// Coordinates the OCR workflow: region selection -> capture -> text recognition
@MainActor
final class OCRCoordinator: ObservableObject {

    // MARK: - Published Properties

    /// Whether region selection is active
    @Published private(set) var isSelecting = false

    /// Whether OCR processing is in progress
    @Published private(set) var isProcessing = false

    /// Last recognized text (if any)
    @Published private(set) var lastRecognizedText: String?

    /// Last error (if any)
    @Published private(set) var lastError: Error?

    // MARK: - Callbacks

    /// Called when OCR completes successfully with recognized text
    var onTextRecognized: ((String) -> Void)?

    /// Called when OCR fails or is cancelled
    var onError: ((Error?) -> Void)?

    // MARK: - Private Properties

    private var overlayWindow: RegionSelectionOverlay?

    /// OCR language preferences
    var recognitionLanguages: [String] = ["ja", "en"]

    /// OCR accuracy level
    var accuracyLevel: OCRService.AccuracyLevel = .accurate

    // MARK: - Public Methods

    /// Start the region selection process
    func startSelection() {
        guard !isSelecting && !isProcessing else {
            dprint("OCRCoordinator: Already selecting or processing")

            return
        }

        // Check screen recording permission
        guard ScreenCaptureService.hasScreenRecordingPermission else {
            dprint("OCRCoordinator: Screen recording permission not granted")

            ScreenCaptureService.requestScreenRecordingPermission()
            onError?(OCRError.permissionDenied)
            return
        }

        isSelecting = true
        lastError = nil

        // Create and show overlay
        overlayWindow = RegionSelectionOverlay()
        overlayWindow?.onSelectionComplete = { [weak self] rect in
            self?.handleSelectionComplete(rect: rect)
        }
        overlayWindow?.onCancel = { [weak self] in
            self?.handleCancel()
        }
        overlayWindow?.beginSelection()
        dprint("OCRCoordinator: Selection started")

    }

    /// Cancel the current selection or processing
    func cancel() {
        if isSelecting {
            overlayWindow?.endSelection()
            overlayWindow = nil
            isSelecting = false
        }

        // Note: Cannot cancel ongoing OCR processing easily
        // It will complete in background
        dprint("OCRCoordinator: Cancelled")

    }

    // MARK: - Private Methods

    private func handleSelectionComplete(rect: CGRect) {
        isSelecting = false
        overlayWindow = nil
        dprint("OCRCoordinator: Selection complete - \(rect)")


        // Start capture and OCR
        Task {
            await captureAndRecognize(rect: rect)
        }
    }

    private func handleCancel() {
        isSelecting = false
        overlayWindow = nil
        dprint("OCRCoordinator: Selection cancelled")


        onError?(nil)  // nil error indicates cancellation
    }

    private func captureAndRecognize(rect: CGRect) async {
        isProcessing = true

        defer {
            isProcessing = false
        }

        do {
            // Step 1: Capture the selected region
            dprint("OCRCoordinator: Capturing region...")


            let image = try ScreenCaptureService.capture(rect: rect)

            // Step 2: Perform OCR
            dprint("OCRCoordinator: Performing OCR...")


            let recognizedText = try await OCRService.recognizeText(
                from: image,
                languages: recognitionLanguages,
                accuracy: accuracyLevel
            )

            // Step 3: Report success
            lastRecognizedText = recognizedText
            lastError = nil
            dprint("OCRCoordinator: OCR complete - \(recognizedText.prefix(100))...")


            onTextRecognized?(recognizedText)

        } catch {
            lastError = error
            lastRecognizedText = nil
            dprint("OCRCoordinator: Error - \(error.localizedDescription)")


            onError?(error)
        }
    }

    // MARK: - Error Types

    enum OCRError: LocalizedError {
        case permissionDenied
        case selectionCancelled

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen recording permission is required for OCR. Please enable it in System Settings > Privacy & Security > Screen Recording."
            case .selectionCancelled:
                return "Selection was cancelled"
            }
        }
    }
}
