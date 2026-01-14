import Foundation
import AVFoundation

/// Utility for converting audio formats
enum AudioConverter {

    // MARK: - PCM to WAV Conversion

    /// Create WAV file from raw PCM data
    /// - Parameters:
    ///   - pcmData: Raw PCM audio data (16-bit signed, little-endian, mono)
    ///   - sampleRate: Sample rate in Hz (default: 24000 for OpenAI/ElevenLabs/Gemini)
    /// - Returns: WAV file data with proper header
    static func createWAVFromPCM(_ pcmData: Data, sampleRate: UInt32 = 24000) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        var wavData = Data()

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // AudioFormat (PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data subchunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        wavData.append(pcmData)

        return wavData
    }

    /// Extract sample rate from MIME type string (e.g., "audio/L16;rate=24000")
    /// - Parameter mimeType: MIME type string
    /// - Returns: Sample rate in Hz, defaults to 24000 if not found
    static func extractSampleRate(from mimeType: String) -> UInt32 {
        if let rateMatch = mimeType.range(of: "rate=") {
            let rateStart = mimeType.index(rateMatch.upperBound, offsetBy: 0)
            var rateEnd = rateStart
            while rateEnd < mimeType.endIndex && mimeType[rateEnd].isNumber {
                rateEnd = mimeType.index(after: rateEnd)
            }
            if let rate = UInt32(mimeType[rateStart..<rateEnd]) {
                return rate
            }
        }
        return 24000  // Default sample rate
    }

    // MARK: - AAC Conversion
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

        // Write input data to temp file on background thread
        let writeSuccess = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try inputData.write(to: inputURL)
                    continuation.resume(returning: true)
                } catch {
                    print("AudioConverter: Failed to write input file: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }

        guard writeSuccess else {
            return nil
        }

        // Perform conversion
        let success = await performConversion(from: inputURL, to: outputURL)

        // Read output and clean up on background thread
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    // Clean up temporary files
                    try? FileManager.default.removeItem(at: inputURL)
                    try? FileManager.default.removeItem(at: outputURL)
                }

                if success {
                    let outputData = try? Data(contentsOf: outputURL)
                    continuation.resume(returning: outputData)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
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
