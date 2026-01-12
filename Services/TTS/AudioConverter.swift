import Foundation
import AVFoundation

/// Utility for converting audio formats
enum AudioConverter {
    /// Convert audio data (AIFF/WAV) to AAC (M4A) format
    /// - Parameters:
    ///   - inputData: Source audio data in AIFF or WAV format
    ///   - inputExtension: File extension of input format ("aiff" or "wav")
    /// - Returns: Converted audio data in M4A format, or nil if conversion fails
    static func convertToAAC(inputData: Data, inputExtension: String) async -> Data? {
        // Create temporary files for conversion
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("convert_input_\(UUID().uuidString).\(inputExtension)")
        let outputURL = tempDir.appendingPathComponent("convert_output_\(UUID().uuidString).m4a")

        defer {
            // Clean up temporary files
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            // Write input data to temp file
            try inputData.write(to: inputURL)

            // Perform conversion
            let success = await performConversion(from: inputURL, to: outputURL)

            if success {
                return try Data(contentsOf: outputURL)
            }
        } catch {
            print("AudioConverter: Error during conversion: \(error)")
        }

        return nil
    }

    /// Perform the actual conversion using AVAssetReader/Writer
    private static func performConversion(from inputURL: URL, to outputURL: URL) async -> Bool {
        let asset = AVAsset(url: inputURL)

        // Get audio track
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            print("AudioConverter: No audio track found")
            return false
        }

        // Set up asset reader
        guard let assetReader = try? AVAssetReader(asset: asset) else {
            print("AudioConverter: Failed to create asset reader")
            return false
        }

        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
        assetReader.add(readerOutput)

        // Set up asset writer
        guard let assetWriter = try? AVAssetWriter(outputURL: outputURL, fileType: .m4a) else {
            print("AudioConverter: Failed to create asset writer")
            return false
        }

        let writerInputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerInputSettings)
        writerInput.expectsMediaDataInRealTime = false
        assetWriter.add(writerInput)

        // Start conversion
        assetReader.startReading()
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: .zero)

        // Process samples
        let processingQueue = DispatchQueue(label: "com.typetalk.audioconverter")

        return await withCheckedContinuation { continuation in
            writerInput.requestMediaDataWhenReady(on: processingQueue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()

                        if assetReader.status == .completed {
                            assetWriter.finishWriting {
                                continuation.resume(returning: assetWriter.status == .completed)
                            }
                        } else {
                            print("AudioConverter: Reader failed with status: \(assetReader.status)")
                            assetWriter.cancelWriting()
                            continuation.resume(returning: false)
                        }
                        return
                    }
                }
            }
        }
    }
}
