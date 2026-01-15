import Foundation
import Vision
import AppKit

/// Service for performing OCR (Optical Character Recognition) on images
enum OCRService {

    /// OCR recognition error types
    enum OCRError: LocalizedError {
        case noTextFound
        case recognitionFailed(Error)
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .noTextFound:
                return "No text was found in the selected region"
            case .recognitionFailed(let error):
                return "Text recognition failed: \(error.localizedDescription)"
            case .invalidImage:
                return "Invalid image for text recognition"
            }
        }
    }

    /// Recognition accuracy level
    enum AccuracyLevel: String, CaseIterable {
        case accurate = "accurate"
        case fast = "fast"

        var vnLevel: VNRequestTextRecognitionLevel {
            switch self {
            case .accurate:
                return .accurate
            case .fast:
                return .fast
            }
        }
    }

    /// Recognize text from a CGImage
    /// - Parameters:
    ///   - image: The image to recognize text from
    ///   - languages: Language codes to prioritize (e.g., ["ja", "en"])
    ///   - accuracy: Recognition accuracy level
    /// - Returns: Recognized text as a single string
    static func recognizeText(
        from image: CGImage,
        languages: [String] = ["ja", "en"],
        accuracy: AccuracyLevel = .accurate
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: OCRError.recognitionFailed(error))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(throwing: OCRError.noTextFound)
                    return
                }

                // Sort observations by position (top to bottom, left to right)
                let sortedObservations = observations.sorted { obs1, obs2 in
                    // Y is inverted in Vision (0 is bottom)
                    let y1 = 1 - obs1.boundingBox.midY
                    let y2 = 1 - obs2.boundingBox.midY

                    // If on roughly the same line (within 2% of image height), sort by X
                    if abs(y1 - y2) < 0.02 {
                        return obs1.boundingBox.midX < obs2.boundingBox.midX
                    }
                    return y1 < y2
                }

                // Extract top candidate from each observation
                let recognizedTexts = sortedObservations.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }

                let fullText = recognizedTexts.joined(separator: "\n")

                if fullText.isEmpty {
                    continuation.resume(throwing: OCRError.noTextFound)
                } else {
                    continuation.resume(returning: fullText)
                }
            }

            // Configure recognition request
            request.recognitionLevel = accuracy.vnLevel
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true

            // Perform recognition
            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: OCRError.recognitionFailed(error))
                }
            }
        }
    }

    /// Get available recognition languages supported by Vision
    static func supportedLanguages(for accuracy: AccuracyLevel = .accurate) -> [String] {
        do {
            let revision = VNRecognizeTextRequestRevision3
            return try VNRecognizeTextRequest.supportedRecognitionLanguages(
                for: accuracy.vnLevel,
                revision: revision
            )
        } catch {
            // Fallback to common languages
            return ["en-US", "ja-JP", "zh-Hans", "zh-Hant", "ko-KR", "de-DE", "fr-FR", "es-ES"]
        }
    }
}
