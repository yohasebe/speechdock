import XCTest
@testable import SpeechDock

final class AppleScriptTests: XCTestCase {

    // MARK: - LanguageCode.fromName Tests

    func testFromName_EnglishNames() {
        XCTAssertEqual(LanguageCode.fromName("English"), .english)
        XCTAssertEqual(LanguageCode.fromName("Japanese"), .japanese)
        XCTAssertEqual(LanguageCode.fromName("Chinese"), .chinese)
        XCTAssertEqual(LanguageCode.fromName("Korean"), .korean)
        XCTAssertEqual(LanguageCode.fromName("Spanish"), .spanish)
        XCTAssertEqual(LanguageCode.fromName("French"), .french)
        XCTAssertEqual(LanguageCode.fromName("German"), .german)
        XCTAssertEqual(LanguageCode.fromName("Italian"), .italian)
        XCTAssertEqual(LanguageCode.fromName("Portuguese"), .portuguese)
        XCTAssertEqual(LanguageCode.fromName("Russian"), .russian)
        XCTAssertEqual(LanguageCode.fromName("Arabic"), .arabic)
        XCTAssertEqual(LanguageCode.fromName("Hindi"), .hindi)
        XCTAssertEqual(LanguageCode.fromName("Dutch"), .dutch)
        XCTAssertEqual(LanguageCode.fromName("Polish"), .polish)
        XCTAssertEqual(LanguageCode.fromName("Turkish"), .turkish)
        XCTAssertEqual(LanguageCode.fromName("Indonesian"), .indonesian)
        XCTAssertEqual(LanguageCode.fromName("Vietnamese"), .vietnamese)
        XCTAssertEqual(LanguageCode.fromName("Thai"), .thai)
        XCTAssertEqual(LanguageCode.fromName("Bengali"), .bengali)
        XCTAssertEqual(LanguageCode.fromName("Gujarati"), .gujarati)
        XCTAssertEqual(LanguageCode.fromName("Kannada"), .kannada)
        XCTAssertEqual(LanguageCode.fromName("Malayalam"), .malayalam)
        XCTAssertEqual(LanguageCode.fromName("Marathi"), .marathi)
        XCTAssertEqual(LanguageCode.fromName("Tamil"), .tamil)
        XCTAssertEqual(LanguageCode.fromName("Telugu"), .telugu)
    }

    func testFromName_CaseInsensitive() {
        XCTAssertEqual(LanguageCode.fromName("japanese"), .japanese)
        XCTAssertEqual(LanguageCode.fromName("JAPANESE"), .japanese)
        XCTAssertEqual(LanguageCode.fromName("Japanese"), .japanese)
        XCTAssertEqual(LanguageCode.fromName("french"), .french)
        XCTAssertEqual(LanguageCode.fromName("FRENCH"), .french)
        XCTAssertEqual(LanguageCode.fromName("english"), .english)
        XCTAssertEqual(LanguageCode.fromName("ENGLISH"), .english)
    }

    func testFromName_NativeNames() {
        XCTAssertEqual(LanguageCode.fromName("日本語"), .japanese)
        XCTAssertEqual(LanguageCode.fromName("中文"), .chinese)
        XCTAssertEqual(LanguageCode.fromName("한국어"), .korean)
        XCTAssertEqual(LanguageCode.fromName("Español"), .spanish)
        XCTAssertEqual(LanguageCode.fromName("Français"), .french)
        XCTAssertEqual(LanguageCode.fromName("Deutsch"), .german)
        XCTAssertEqual(LanguageCode.fromName("Italiano"), .italian)
        XCTAssertEqual(LanguageCode.fromName("Português"), .portuguese)
        XCTAssertEqual(LanguageCode.fromName("Русский"), .russian)
        XCTAssertEqual(LanguageCode.fromName("العربية"), .arabic)
        XCTAssertEqual(LanguageCode.fromName("हिन्दी"), .hindi)
        XCTAssertEqual(LanguageCode.fromName("Nederlands"), .dutch)
        XCTAssertEqual(LanguageCode.fromName("Polski"), .polish)
        XCTAssertEqual(LanguageCode.fromName("Türkçe"), .turkish)
    }

    func testFromName_RawCodes() {
        XCTAssertEqual(LanguageCode.fromName("en"), .english)
        XCTAssertEqual(LanguageCode.fromName("ja"), .japanese)
        XCTAssertEqual(LanguageCode.fromName("zh"), .chinese)
        XCTAssertEqual(LanguageCode.fromName("ko"), .korean)
        XCTAssertEqual(LanguageCode.fromName("es"), .spanish)
        XCTAssertEqual(LanguageCode.fromName("fr"), .french)
        XCTAssertEqual(LanguageCode.fromName("de"), .german)
    }

    func testFromName_InvalidNames() {
        XCTAssertNil(LanguageCode.fromName(""))
        XCTAssertNil(LanguageCode.fromName("Klingon"))
        XCTAssertNil(LanguageCode.fromName("xyz"))
        XCTAssertNil(LanguageCode.fromName("Auto"))
        XCTAssertNil(LanguageCode.fromName("123"))
    }

    func testFromName_DoesNotMatchAuto() {
        // "Auto" should not resolve to a language (it's not a valid translation target)
        XCTAssertNil(LanguageCode.fromName("Auto"))
        XCTAssertNil(LanguageCode.fromName("auto"))
    }

    // MARK: - LanguageCode.englishName Tests

    func testEnglishName_AllLanguages() {
        // Verify all non-auto languages have non-empty English names
        for lang in LanguageCode.allCases where lang != .auto {
            XCTAssertFalse(lang.englishName.isEmpty, "\(lang.rawValue) has empty englishName")
        }
    }

    func testEnglishName_SpecificValues() {
        XCTAssertEqual(LanguageCode.english.englishName, "English")
        XCTAssertEqual(LanguageCode.japanese.englishName, "Japanese")
        XCTAssertEqual(LanguageCode.chinese.englishName, "Chinese")
        XCTAssertEqual(LanguageCode.auto.englishName, "Auto")
    }

    func testEnglishName_RoundTrip() {
        // Every language's englishName should resolve back to itself via fromName
        for lang in LanguageCode.allCases where lang != .auto {
            let resolved = LanguageCode.fromName(lang.englishName)
            XCTAssertEqual(resolved, lang, "Round-trip failed for \(lang.englishName)")
        }
    }

    // MARK: - AppleScriptErrorCode Tests

    func testErrorCode_TTSRange() {
        // TTS errors should be in 1010-1019 range
        XCTAssertEqual(AppleScriptErrorCode.ttsEmptyText.rawValue, 1010)
        XCTAssertEqual(AppleScriptErrorCode.ttsNotSpeaking.rawValue, 1011)
        XCTAssertEqual(AppleScriptErrorCode.ttsNotPaused.rawValue, 1012)
        XCTAssertEqual(AppleScriptErrorCode.ttsAlreadySpeaking.rawValue, 1013)
        XCTAssertEqual(AppleScriptErrorCode.ttsProviderError.rawValue, 1014)
        XCTAssertEqual(AppleScriptErrorCode.ttsSavePathInvalid.rawValue, 1015)
        XCTAssertEqual(AppleScriptErrorCode.ttsSaveDirectoryNotFound.rawValue, 1016)
        XCTAssertEqual(AppleScriptErrorCode.ttsSaveFailed.rawValue, 1017)
        XCTAssertEqual(AppleScriptErrorCode.ttsTextTooShort.rawValue, 1018)
    }

    func testErrorCode_STTRange() {
        // STT errors should be in 1020-1029 range
        XCTAssertEqual(AppleScriptErrorCode.sttProviderNotSupported.rawValue, 1020)
        XCTAssertEqual(AppleScriptErrorCode.sttFileNotFound.rawValue, 1021)
        XCTAssertEqual(AppleScriptErrorCode.sttUnsupportedFormat.rawValue, 1022)
        XCTAssertEqual(AppleScriptErrorCode.sttFileTooLarge.rawValue, 1023)
        XCTAssertEqual(AppleScriptErrorCode.sttAlreadyRecording.rawValue, 1024)
        XCTAssertEqual(AppleScriptErrorCode.sttTranscriptionFailed.rawValue, 1025)
        XCTAssertEqual(AppleScriptErrorCode.sttNotRecording.rawValue, 1026)
    }

    func testErrorCode_TranslationRange() {
        // Translation errors should be in 1030-1039 range
        XCTAssertEqual(AppleScriptErrorCode.translationEmptyText.rawValue, 1030)
        XCTAssertEqual(AppleScriptErrorCode.translationInvalidLanguage.rawValue, 1031)
        XCTAssertEqual(AppleScriptErrorCode.translationFailed.rawValue, 1032)
        XCTAssertEqual(AppleScriptErrorCode.translationProviderUnavailable.rawValue, 1033)
    }

    func testErrorCode_ProviderRange() {
        // Provider errors should be in 1040-1049 range
        XCTAssertEqual(AppleScriptErrorCode.invalidProviderName.rawValue, 1040)
        XCTAssertEqual(AppleScriptErrorCode.invalidSpeed.rawValue, 1042)
        XCTAssertEqual(AppleScriptErrorCode.apiKeyNotConfigured.rawValue, 1043)
    }

    func testErrorCode_ClipboardRange() {
        // Clipboard errors should be in 1050-1059 range
        XCTAssertEqual(AppleScriptErrorCode.clipboardEmptyText.rawValue, 1050)
        XCTAssertEqual(AppleScriptErrorCode.clipboardPasteFailed.rawValue, 1051)
    }

    func testErrorCode_GeneralRange() {
        XCTAssertEqual(AppleScriptErrorCode.internalError.rawValue, 1000)
        XCTAssertEqual(AppleScriptErrorCode.invalidParameter.rawValue, 1001)
    }

    func testErrorCode_UniqueValues() {
        // All error codes should be unique
        let allCodes: [AppleScriptErrorCode] = [
            .internalError, .invalidParameter,
            .ttsEmptyText, .ttsNotSpeaking, .ttsNotPaused, .ttsAlreadySpeaking,
            .ttsProviderError, .ttsSavePathInvalid, .ttsSaveDirectoryNotFound,
            .ttsSaveFailed, .ttsTextTooShort,
            .sttProviderNotSupported, .sttFileNotFound, .sttUnsupportedFormat,
            .sttFileTooLarge, .sttAlreadyRecording, .sttTranscriptionFailed,
            .translationEmptyText, .translationInvalidLanguage,
            .translationFailed, .translationProviderUnavailable,
            .invalidProviderName, .invalidSpeed, .apiKeyNotConfigured,
            .clipboardEmptyText, .clipboardPasteFailed
        ]
        let rawValues = allCodes.map { $0.rawValue }
        let uniqueValues = Set(rawValues)
        XCTAssertEqual(rawValues.count, uniqueValues.count, "Error codes must be unique")
    }

    // MARK: - NSScriptCommand Extension Tests

    func testSetAppleScriptError() {
        let command = NSScriptCommand()
        command.setAppleScriptError(.ttsEmptyText, message: "Test error message")
        XCTAssertEqual(command.scriptErrorNumber, 1010)
        XCTAssertEqual(command.scriptErrorString, "Test error message")
    }

    func testSetAppleScriptError_DifferentCodes() {
        let command = NSScriptCommand()

        command.setAppleScriptError(.sttFileNotFound, message: "File not found")
        XCTAssertEqual(command.scriptErrorNumber, 1021)
        XCTAssertEqual(command.scriptErrorString, "File not found")

        command.setAppleScriptError(.translationInvalidLanguage, message: "Unknown language")
        XCTAssertEqual(command.scriptErrorNumber, 1031)
        XCTAssertEqual(command.scriptErrorString, "Unknown language")
    }

    // MARK: - Provider Name Validation Tests

    func testTTSProviderRawValues() {
        // Verify the raw values that AppleScript users will use
        XCTAssertEqual(TTSProvider(rawValue: "macOS"), .macOS)
        XCTAssertEqual(TTSProvider(rawValue: "OpenAI"), .openAI)
        XCTAssertEqual(TTSProvider(rawValue: "Gemini"), .gemini)
        XCTAssertEqual(TTSProvider(rawValue: "ElevenLabs"), .elevenLabs)
        XCTAssertEqual(TTSProvider(rawValue: "Grok"), .grok)
        XCTAssertNil(TTSProvider(rawValue: "invalid"))
        XCTAssertNil(TTSProvider(rawValue: "openai"))  // case-sensitive
        XCTAssertNil(TTSProvider(rawValue: ""))
    }

    func testSTTProviderRawValues() {
        XCTAssertEqual(RealtimeSTTProvider(rawValue: "macOS"), .macOS)
        XCTAssertEqual(RealtimeSTTProvider(rawValue: "OpenAI"), .openAI)
        XCTAssertEqual(RealtimeSTTProvider(rawValue: "Gemini"), .gemini)
        XCTAssertEqual(RealtimeSTTProvider(rawValue: "ElevenLabs"), .elevenLabs)
        XCTAssertEqual(RealtimeSTTProvider(rawValue: "Grok"), .grok)
        XCTAssertNil(RealtimeSTTProvider(rawValue: "invalid"))
    }

    func testTranslationProviderRawValues() {
        XCTAssertEqual(TranslationProvider(rawValue: "macOS"), .macOS)
        XCTAssertEqual(TranslationProvider(rawValue: "OpenAI"), .openAI)
        XCTAssertEqual(TranslationProvider(rawValue: "Gemini"), .gemini)
        XCTAssertEqual(TranslationProvider(rawValue: "Grok"), .grok)
        XCTAssertNil(TranslationProvider(rawValue: "ElevenLabs"))  // not a translation provider
        XCTAssertNil(TranslationProvider(rawValue: "invalid"))
    }

    // MARK: - File Transcription Support Tests

    func testFileTranscriptionSupport() {
        // Providers that support file transcription
        XCTAssertTrue(RealtimeSTTProvider.openAI.supportsFileTranscription)
        XCTAssertTrue(RealtimeSTTProvider.gemini.supportsFileTranscription)
        XCTAssertTrue(RealtimeSTTProvider.elevenLabs.supportsFileTranscription)

        // Providers that do NOT support file transcription
        XCTAssertFalse(RealtimeSTTProvider.macOS.supportsFileTranscription)
        XCTAssertFalse(RealtimeSTTProvider.grok.supportsFileTranscription)
    }

    // MARK: - API Key Requirement Tests

    func testTTSProviderRequiresAPIKey() {
        XCTAssertFalse(TTSProvider.macOS.requiresAPIKey)
        XCTAssertTrue(TTSProvider.openAI.requiresAPIKey)
        XCTAssertTrue(TTSProvider.gemini.requiresAPIKey)
        XCTAssertTrue(TTSProvider.elevenLabs.requiresAPIKey)
        XCTAssertTrue(TTSProvider.grok.requiresAPIKey)
    }

    func testSTTProviderRequiresAPIKey() {
        XCTAssertFalse(RealtimeSTTProvider.macOS.requiresAPIKey)
        XCTAssertTrue(RealtimeSTTProvider.openAI.requiresAPIKey)
        XCTAssertTrue(RealtimeSTTProvider.gemini.requiresAPIKey)
        XCTAssertTrue(RealtimeSTTProvider.elevenLabs.requiresAPIKey)
        XCTAssertTrue(RealtimeSTTProvider.grok.requiresAPIKey)
    }

    func testTranslationProviderRequiresAPIKey() {
        XCTAssertFalse(TranslationProvider.macOS.requiresAPIKey)
        XCTAssertTrue(TranslationProvider.openAI.requiresAPIKey)
        XCTAssertTrue(TranslationProvider.gemini.requiresAPIKey)
        XCTAssertTrue(TranslationProvider.grok.requiresAPIKey)
    }

    // MARK: - Speed Clamping Tests

    func testSpeedClamping() {
        // Test the clamping logic used in AppleScriptBridge
        let clamp: (Double) -> Double = { min(max($0, 0.25), 4.0) }

        XCTAssertEqual(clamp(1.0), 1.0)
        XCTAssertEqual(clamp(0.25), 0.25)
        XCTAssertEqual(clamp(4.0), 4.0)
        XCTAssertEqual(clamp(0.0), 0.25)    // below min
        XCTAssertEqual(clamp(-1.0), 0.25)   // below min
        XCTAssertEqual(clamp(5.0), 4.0)     // above max
        XCTAssertEqual(clamp(100.0), 4.0)   // above max
        XCTAssertEqual(clamp(1.5), 1.5)     // normal
    }
}
