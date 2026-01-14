import XCTest
@testable import TypeTalk

final class AudioConverterTests: XCTestCase {

    // MARK: - WAV Header Structure Tests

    func testCreateWAVFromPCM_HeaderStructure() {
        // Create minimal PCM data (2 samples = 4 bytes)
        let pcmData = Data([0x00, 0x01, 0x02, 0x03])

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // WAV header is 44 bytes + PCM data
        XCTAssertEqual(wavData.count, 44 + pcmData.count)

        // Verify RIFF header
        let riffHeader = String(data: wavData[0..<4], encoding: .ascii)
        XCTAssertEqual(riffHeader, "RIFF")

        // Verify WAVE format
        let waveFormat = String(data: wavData[8..<12], encoding: .ascii)
        XCTAssertEqual(waveFormat, "WAVE")

        // Verify fmt subchunk
        let fmtChunk = String(data: wavData[12..<16], encoding: .ascii)
        XCTAssertEqual(fmtChunk, "fmt ")

        // Verify data subchunk
        let dataChunk = String(data: wavData[36..<40], encoding: .ascii)
        XCTAssertEqual(dataChunk, "data")
    }

    func testCreateWAVFromPCM_DefaultSampleRate() {
        let pcmData = Data([0x00, 0x01, 0x02, 0x03])

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Sample rate is at bytes 24-27 (little-endian UInt32)
        let sampleRateBytes = wavData[24..<28]
        let sampleRate = sampleRateBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(sampleRate, 24000)
    }

    func testCreateWAVFromPCM_CustomSampleRate() {
        let pcmData = Data([0x00, 0x01, 0x02, 0x03])

        let wavData = AudioConverter.createWAVFromPCM(pcmData, sampleRate: 44100)

        // Sample rate is at bytes 24-27 (little-endian UInt32)
        let sampleRateBytes = wavData[24..<28]
        let sampleRate = sampleRateBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(sampleRate, 44100)
    }

    func testCreateWAVFromPCM_AudioFormat() {
        let pcmData = Data([0x00, 0x01])

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Audio format is at bytes 20-21 (little-endian UInt16)
        // Format 1 = PCM
        let formatBytes = wavData[20..<22]
        let format = formatBytes.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        XCTAssertEqual(format, 1, "Audio format should be 1 (PCM)")
    }

    func testCreateWAVFromPCM_MonoChannel() {
        let pcmData = Data([0x00, 0x01])

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Number of channels is at bytes 22-23 (little-endian UInt16)
        let channelsBytes = wavData[22..<24]
        let channels = channelsBytes.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        XCTAssertEqual(channels, 1, "Should be mono (1 channel)")
    }

    func testCreateWAVFromPCM_BitsPerSample() {
        let pcmData = Data([0x00, 0x01])

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Bits per sample is at bytes 34-35 (little-endian UInt16)
        let bitsBytes = wavData[34..<36]
        let bitsPerSample = bitsBytes.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        XCTAssertEqual(bitsPerSample, 16, "Should be 16-bit audio")
    }

    func testCreateWAVFromPCM_DataSize() {
        let pcmData = Data(repeating: 0x00, count: 1000)

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Data size is at bytes 40-43 (little-endian UInt32)
        let dataSizeBytes = wavData[40..<44]
        let dataSize = dataSizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(dataSize, UInt32(pcmData.count))
    }

    func testCreateWAVFromPCM_ChunkSize() {
        let pcmData = Data(repeating: 0x00, count: 100)

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Chunk size is at bytes 4-7 (little-endian UInt32)
        // Should be 36 + data size
        let chunkSizeBytes = wavData[4..<8]
        let chunkSize = chunkSizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(chunkSize, 36 + UInt32(pcmData.count))
    }

    func testCreateWAVFromPCM_EmptyData() {
        let pcmData = Data()

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // Should still produce valid header (44 bytes)
        XCTAssertEqual(wavData.count, 44)
    }

    func testCreateWAVFromPCM_PCMDataPreserved() {
        // Create recognizable PCM pattern
        let pcmData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // PCM data starts at byte 44
        let extractedPCM = wavData[44..<wavData.count]
        XCTAssertEqual(Data(extractedPCM), pcmData)
    }

    // MARK: - Sample Rate Extraction Tests

    func testExtractSampleRate_StandardFormat() {
        let mimeType = "audio/L16;rate=24000"
        let rate = AudioConverter.extractSampleRate(from: mimeType)
        XCTAssertEqual(rate, 24000)
    }

    func testExtractSampleRate_HighRate() {
        let mimeType = "audio/pcm;rate=44100"
        let rate = AudioConverter.extractSampleRate(from: mimeType)
        XCTAssertEqual(rate, 44100)
    }

    func testExtractSampleRate_LowRate() {
        let mimeType = "audio/L16;rate=8000"
        let rate = AudioConverter.extractSampleRate(from: mimeType)
        XCTAssertEqual(rate, 8000)
    }

    func testExtractSampleRate_NoRate() {
        let mimeType = "audio/L16"
        let rate = AudioConverter.extractSampleRate(from: mimeType)
        XCTAssertEqual(rate, 24000, "Should default to 24000 when rate not specified")
    }

    func testExtractSampleRate_EmptyString() {
        let mimeType = ""
        let rate = AudioConverter.extractSampleRate(from: mimeType)
        XCTAssertEqual(rate, 24000, "Should default to 24000 for empty string")
    }

    func testExtractSampleRate_MalformedRate() {
        let mimeType = "audio/L16;rate=abc"
        let rate = AudioConverter.extractSampleRate(from: mimeType)
        XCTAssertEqual(rate, 24000, "Should default to 24000 for malformed rate")
    }

    func testExtractSampleRate_WithAdditionalParams() {
        let mimeType = "audio/L16;rate=48000;channels=1;bits=16"
        let rate = AudioConverter.extractSampleRate(from: mimeType)
        XCTAssertEqual(rate, 48000)
    }

    func testExtractSampleRate_RateAtEnd() {
        let mimeType = "audio/pcm;channels=1;rate=16000"
        let rate = AudioConverter.extractSampleRate(from: mimeType)
        XCTAssertEqual(rate, 16000)
    }

    // MARK: - ByteRate Calculation Tests

    func testCreateWAVFromPCM_ByteRate() {
        let pcmData = Data([0x00, 0x01])

        // Test with different sample rates
        let rates: [UInt32] = [8000, 16000, 24000, 44100, 48000]

        for sampleRate in rates {
            let wavData = AudioConverter.createWAVFromPCM(pcmData, sampleRate: sampleRate)

            // ByteRate is at bytes 28-31 (little-endian UInt32)
            // ByteRate = SampleRate * NumChannels * BitsPerSample/8
            // For mono 16-bit: ByteRate = SampleRate * 1 * 2 = SampleRate * 2
            let byteRateBytes = wavData[28..<32]
            let byteRate = byteRateBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            XCTAssertEqual(byteRate, sampleRate * 2, "ByteRate should be \(sampleRate * 2) for sample rate \(sampleRate)")
        }
    }

    // MARK: - Block Align Tests

    func testCreateWAVFromPCM_BlockAlign() {
        let pcmData = Data([0x00, 0x01])

        let wavData = AudioConverter.createWAVFromPCM(pcmData)

        // BlockAlign is at bytes 32-33 (little-endian UInt16)
        // BlockAlign = NumChannels * BitsPerSample/8
        // For mono 16-bit: BlockAlign = 1 * 2 = 2
        let blockAlignBytes = wavData[32..<34]
        let blockAlign = blockAlignBytes.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        XCTAssertEqual(blockAlign, 2, "BlockAlign should be 2 for mono 16-bit")
    }
}
