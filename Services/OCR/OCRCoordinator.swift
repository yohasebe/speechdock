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
            #if DEBUG
            print("OCRCoordinator: Already selecting or processing")
            #endif
            return
        }

        // Check screen recording permission
        guard ScreenCaptureService.hasScreenRecordingPermission else {
            #if DEBUG
            print("OCRCoordinator: Screen recording permission not granted")
            #endif
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

        #if DEBUG
        print("OCRCoordinator: Selection started")
        #endif
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

        #if DEBUG
        print("OCRCoordinator: Cancelled")
        #endif
    }

    // MARK: - Private Methods

    private func handleSelectionComplete(rect: CGRect) {
        isSelecting = false
        overlayWindow = nil

        #if DEBUG
        print("OCRCoordinator: Selection complete - \(rect)")
        #endif

        // Start capture and OCR
        Task {
            await captureAndRecognize(rect: rect)
        }
    }

    private func handleCancel() {
        isSelecting = false
        overlayWindow = nil

        #if DEBUG
        print("OCRCoordinator: Selection cancelled")
        #endif

        onError?(nil)  // nil error indicates cancellation
    }

    private func captureAndRecognize(rect: CGRect) async {
        isProcessing = true

        defer {
            isProcessing = false
        }

        do {
            // Step 1: Capture the selected region
            #if DEBUG
            print("OCRCoordinator: Capturing region...")
            #endif

            let image = try ScreenCaptureService.capture(rect: rect)

            // Step 2: Perform OCR
            #if DEBUG
            print("OCRCoordinator: Performing OCR...")
            #endif

            let recognizedText = try await OCRService.recognizeText(
                from: image,
                languages: recognitionLanguages,
                accuracy: accuracyLevel
            )

            // Step 3: Report success
            lastRecognizedText = recognizedText
            lastError = nil

            #if DEBUG
            print("OCRCoordinator: OCR complete - \(recognizedText.prefix(100))...")
            #endif

            onTextRecognized?(recognizedText)

        } catch {
            lastError = error
            lastRecognizedText = nil

            #if DEBUG
            print("OCRCoordinator: Error - \(error.localizedDescription)")
            #endif

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
