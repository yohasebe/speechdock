import XCTest
@testable import SpeechDock

final class FileTranscriptionServiceTests: XCTestCase {

    // MARK: - Provider Support Tests

    func testProviderSupportsFileTranscription_OpenAI() {
        XCTAssertTrue(RealtimeSTTProvider.openAI.supportsFileTranscription)
    }

    func testProviderSupportsFileTranscription_Gemini() {
        XCTAssertTrue(RealtimeSTTProvider.gemini.supportsFileTranscription)
    }

    func testProviderSupportsFileTranscription_ElevenLabs() {
        XCTAssertTrue(RealtimeSTTProvider.elevenLabs.supportsFileTranscription)
    }

    func testProviderSupportsFileTranscription_Grok() {
        XCTAssertFalse(RealtimeSTTProvider.grok.supportsFileTranscription)
    }

    func testProviderSupportsFileTranscription_MacOS() {
        XCTAssertFalse(RealtimeSTTProvider.macOS.supportsFileTranscription)
    }

    // MARK: - Max File Size Tests

    func testMaxFileSizeMB_OpenAI() {
        XCTAssertEqual(RealtimeSTTProvider.openAI.maxFileSizeMB, 25)
    }

    func testMaxFileSizeMB_Gemini() {
        XCTAssertEqual(RealtimeSTTProvider.gemini.maxFileSizeMB, 20)
    }

    func testMaxFileSizeMB_ElevenLabs() {
        XCTAssertEqual(RealtimeSTTProvider.elevenLabs.maxFileSizeMB, 25)
    }

    func testMaxFileSizeMB_UnsupportedProviders() {
        XCTAssertEqual(RealtimeSTTProvider.grok.maxFileSizeMB, 0)
        XCTAssertEqual(RealtimeSTTProvider.macOS.maxFileSizeMB, 0)
    }

    // MARK: - Supported Audio Formats Tests

    func testSupportedAudioFormats_OpenAI() {
        let formats = RealtimeSTTProvider.openAI.supportedAudioFormats
        XCTAssertTrue(formats.contains("MP3"))
        XCTAssertTrue(formats.contains("WAV"))
        XCTAssertTrue(formats.contains("M4A"))
    }

    func testSupportedAudioFormats_Gemini() {
        let formats = RealtimeSTTProvider.gemini.supportedAudioFormats
        XCTAssertTrue(formats.contains("MP3"))
        XCTAssertTrue(formats.contains("WAV"))
        XCTAssertTrue(formats.contains("OGG"))
    }

    func testSupportedAudioFormats_ElevenLabs() {
        let formats = RealtimeSTTProvider.elevenLabs.supportedAudioFormats
        XCTAssertTrue(formats.contains("MP3"))
        XCTAssertTrue(formats.contains("WAV"))
        XCTAssertTrue(formats.contains("FLAC"))
    }

    func testSupportedAudioFormats_UnsupportedProviders() {
        XCTAssertEqual(RealtimeSTTProvider.grok.supportedAudioFormats, "")
        XCTAssertEqual(RealtimeSTTProvider.macOS.supportedAudioFormats, "")
    }

    // MARK: - FileTranscriptionError Tests

    func testFileTranscriptionError_FileNotFound() {
        let error = FileTranscriptionError.fileNotFound
        XCTAssertEqual(error.errorDescription, "Audio file not found")
    }

    func testFileTranscriptionError_UnsupportedFormat() {
        let error = FileTranscriptionError.unsupportedFormat("xyz", supportedFormats: "MP3, WAV")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("xyz"))
        XCTAssertTrue(error.errorDescription!.contains("MP3, WAV"))
    }

    func testFileTranscriptionError_FileTooLarge() {
        let error = FileTranscriptionError.fileTooLarge(maxMB: 25, actualMB: 50)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("50"))
        XCTAssertTrue(error.errorDescription!.contains("25"))
    }

    func testFileTranscriptionError_ProviderNotSupported() {
        let error = FileTranscriptionError.providerNotSupported(.grok)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Grok"))
    }

    func testFileTranscriptionError_ReadError() {
        let underlyingError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "File read failed"])
        let error = FileTranscriptionError.readError(underlyingError)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("File read failed"))
    }

    func testFileTranscriptionError_TranscriptionFailed() {
        let underlyingError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "API error"])
        let error = FileTranscriptionError.transcriptionFailed(underlyingError)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("API error"))
    }

    // MARK: - File Validation Tests (using temp files)

    @MainActor
    func testValidateFile_FileNotFound() async throws {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file.mp3")
        let service = FileTranscriptionService.shared

        do {
            try service.validateFile(nonExistentURL, for: .openAI)
            XCTFail("Should throw fileNotFound error")
        } catch let error as FileTranscriptionError {
            if case .fileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected fileNotFound, got \(error)")
            }
        }
    }

    @MainActor
    func testValidateFile_UnsupportedFormat() async throws {
        // Create a temp file with unsupported extension
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test.xyz")
        try "test".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let service = FileTranscriptionService.shared

        do {
            try service.validateFile(tempFile, for: .openAI)
            XCTFail("Should throw unsupportedFormat error")
        } catch let error as FileTranscriptionError {
            if case .unsupportedFormat(let format, _) = error {
                XCTAssertEqual(format, "xyz")
            } else {
                XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
    }

    @MainActor
    func testValidateFile_SupportedFormat() async throws {
        // Create a temp file with supported extension
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test.mp3")
        try "test".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let service = FileTranscriptionService.shared

        // Should not throw for supported format (file is small enough)
        XCTAssertNoThrow(try service.validateFile(tempFile, for: .openAI))
    }

    @MainActor
    func testValidateFile_AllSupportedExtensions() async throws {
        let supportedExtensions = ["mp3", "wav", "m4a", "aac", "webm", "ogg", "flac", "mp4"]
        let tempDir = FileManager.default.temporaryDirectory
        let service = FileTranscriptionService.shared

        for ext in supportedExtensions {
            let tempFile = tempDir.appendingPathComponent("test.\(ext)")
            try "test".write(to: tempFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            XCTAssertNoThrow(try service.validateFile(tempFile, for: .openAI),
                           "Extension .\(ext) should be supported")
        }
    }
}
