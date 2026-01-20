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

                let fullText = formatObservationsWithLayout(observations)

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

    /// Format observations preserving original layout structure
    private static func formatObservationsWithLayout(_ observations: [VNRecognizedTextObservation]) -> String {
        // Extract text with position info
        struct TextBlock {
            let text: String
            let minX: CGFloat      // Left edge (0-1, normalized)
            let midY: CGFloat      // Vertical center (0-1, 0=bottom in Vision)
            let height: CGFloat    // Height of the text block
        }

        let blocks: [TextBlock] = observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            return TextBlock(
                text: text,
                minX: obs.boundingBox.minX,
                midY: obs.boundingBox.midY,
                height: obs.boundingBox.height
            )
        }

        guard !blocks.isEmpty else { return "" }

        // Sort by Y (top to bottom - Vision Y is inverted, so we sort descending)
        // Then by X (left to right) for items on the same line
        let sortedBlocks = blocks.sorted { b1, b2 in
            let y1 = b1.midY
            let y2 = b2.midY
            // Average height for line detection threshold
            let avgHeight = (b1.height + b2.height) / 2

            // If on roughly the same line (within half the average text height)
            if abs(y1 - y2) < avgHeight * 0.5 {
                return b1.minX < b2.minX
            }
            // Higher Y value = higher on screen in Vision coordinates
            return y1 > y2
        }

        // Group blocks into lines based on Y position
        var lines: [[TextBlock]] = []
        var currentLine: [TextBlock] = []
        var lastY: CGFloat?

        for block in sortedBlocks {
            if let prevY = lastY {
                let avgHeight = currentLine.map { $0.height }.reduce(0, +) / CGFloat(currentLine.count)
                // If Y difference is significant, start a new line
                if abs(prevY - block.midY) > avgHeight * 0.5 {
                    if !currentLine.isEmpty {
                        lines.append(currentLine)
                    }
                    currentLine = [block]
                } else {
                    currentLine.append(block)
                }
            } else {
                currentLine.append(block)
            }
            lastY = block.midY
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        // Detect left margin for indentation detection
        let allMinX = sortedBlocks.map { $0.minX }
        let baseIndent = allMinX.min() ?? 0

        // Build output with layout preservation
        var result: [String] = []
        var previousLineY: CGFloat?

        for line in lines {
            // Sort line by X position
            let sortedLine = line.sorted { $0.minX < $1.minX }

            // Check for paragraph break (larger vertical gap)
            if let prevY = previousLineY {
                let avgHeight = line.map { $0.height }.reduce(0, +) / CGFloat(line.count)
                let gap = prevY - (line.first?.midY ?? prevY)
                // If gap is more than 1.5x the text height, it's likely a paragraph break
                if gap > avgHeight * 1.5 {
                    result.append("")  // Add blank line for paragraph
                }
            }

            // Check for indentation (list items, quotes, etc.)
            let lineMinX = sortedLine.first?.minX ?? baseIndent
            let indentLevel = Int((lineMinX - baseIndent) / 0.03)  // ~3% indent = 1 level

            // Join text blocks on the same line
            let lineText = sortedLine.map { $0.text }.joined(separator: " ")

            // Add indentation if detected
            if indentLevel > 0 {
                let indent = String(repeating: "  ", count: min(indentLevel, 4))  // Max 4 levels
                result.append(indent + lineText)
            } else {
                result.append(lineText)
            }

            previousLineY = line.first?.midY
        }

        return result.joined(separator: "\n")
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
