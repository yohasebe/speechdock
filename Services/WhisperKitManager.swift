import Foundation
import AVFoundation
import WhisperKit

/// Available WhisperKit model variants
enum WhisperModelVariant: String, CaseIterable, Identifiable, Codable {
    // Multilingual models
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case medium = "openai_whisper-medium"
    case largev2 = "openai_whisper-large-v2"
    case largev3 = "openai_whisper-large-v3"
    case largev3Turbo = "openai_whisper-large-v3-turbo"
    // English-only models (faster, smaller)
    case tinyEn = "openai_whisper-tiny.en"
    case baseEn = "openai_whisper-base.en"
    case smallEn = "openai_whisper-small.en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largev2: return "Large v2"
        case .largev3: return "Large v3"
        case .largev3Turbo: return "Large v3 Turbo"
        case .tinyEn: return "Tiny (English)"
        case .baseEn: return "Base (English)"
        case .smallEn: return "Small (English)"
        }
    }

    var description: String {
        switch self {
        case .tiny: return "Multilingual, fastest (~39MB)"
        case .base: return "Multilingual, fast (~74MB)"
        case .small: return "Multilingual, balanced (~244MB)"
        case .medium: return "Multilingual, high accuracy (~769MB)"
        case .largev2: return "Multilingual, very high accuracy (~1.5GB)"
        case .largev3: return "Multilingual, best accuracy (~1.5GB)"
        case .largev3Turbo: return "Multilingual, fast + accurate (~800MB)"
        case .tinyEn: return "English only, fastest (~39MB)"
        case .baseEn: return "English only, fast (~74MB)"
        case .smallEn: return "English only, balanced (~244MB)"
        }
    }

    var isRecommended: Bool {
        self == .base || self == .small
    }

    var isEnglishOnly: Bool {
        switch self {
        case .tinyEn, .baseEn, .smallEn:
            return true
        default:
            return false
        }
    }
}

/// Download state for a model
enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case error(String)
}

/// Manager for WhisperKit models
@MainActor
final class WhisperKitManager: ObservableObject {
    static let shared = WhisperKitManager()

    @Published private(set) var downloadStates: [WhisperModelVariant: ModelDownloadState] = [:]
    @Published private(set) var selectedModel: WhisperModelVariant?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var whisperKit: WhisperKit?
    @Published private(set) var availableModels: [String] = []

    private let userDefaultsKey = "whisperKitSelectedModel"
    private var downloadTasks: [WhisperModelVariant: Task<Void, Never>] = [:]

    private init() {
        loadSelectedModel()
        Task {
            await refreshModelStates()
            // Auto-load selected model if it's downloaded
            if let model = selectedModel, downloadStates[model] == .downloaded {
                await loadWhisperKit()
            }
        }
    }

    // MARK: - Model Selection

    private func loadSelectedModel() {
        if let savedModel = UserDefaults.standard.string(forKey: userDefaultsKey),
           let model = WhisperModelVariant(rawValue: savedModel) {
            selectedModel = model
        }
    }

    func selectModel(_ model: WhisperModelVariant) {
        selectedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: userDefaultsKey)

        // Always load the selected model
        Task {
            await loadWhisperKit()
        }
    }

    // MARK: - Model State Management

    func refreshModelStates() async {
        // Get list of available models from WhisperKit
        do {
            availableModels = try await WhisperKit.fetchAvailableModels()
        } catch {
            #if DEBUG
            print("WhisperKitManager: Failed to fetch available models: \(error)")
            #endif
        }

        // Check which models are downloaded locally
        for variant in WhisperModelVariant.allCases {
            if isModelDownloaded(variant.rawValue) {
                downloadStates[variant] = .downloaded
            } else {
                downloadStates[variant] = .notDownloaded
            }
        }
    }

    private func isModelDownloaded(_ modelName: String) -> Bool {
        // Check if model exists in WhisperKit's default location
        let modelPath = getModelPath(for: modelName)
        return FileManager.default.fileExists(atPath: modelPath)
    }

    private func getModelPath(for modelName: String) -> String {
        // WhisperKit stores models in Documents/huggingface/models/argmaxinc/whisperkit-coreml
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = documentsPath.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        return modelsDir.appendingPathComponent(modelName).path
    }

    // MARK: - Model Download

    func downloadModel(_ variant: WhisperModelVariant) {
        guard downloadStates[variant] != .downloading(progress: 0) else { return }

        downloadStates[variant] = .downloading(progress: 0)

        let task = Task {
            do {
                // Download model using WhisperKit's built-in download
                _ = try await WhisperKit.download(
                    variant: variant.rawValue,
                    progressCallback: { progress in
                        Task { @MainActor in
                            self.downloadStates[variant] = .downloading(progress: progress.fractionCompleted)
                        }
                    }
                )

                await MainActor.run {
                    self.downloadStates[variant] = .downloaded
                }

                #if DEBUG
                print("WhisperKitManager: Downloaded model \(variant.rawValue)")
                #endif
            } catch {
                await MainActor.run {
                    self.downloadStates[variant] = .error(error.localizedDescription)
                }
                #if DEBUG
                print("WhisperKitManager: Failed to download model \(variant.rawValue): \(error)")
                #endif
            }
        }

        downloadTasks[variant] = task
    }

    func cancelDownload(_ variant: WhisperModelVariant) {
        downloadTasks[variant]?.cancel()
        downloadTasks[variant] = nil
        downloadStates[variant] = .notDownloaded
    }

    func deleteModel(_ variant: WhisperModelVariant) {
        let modelPath = getModelPath(for: variant.rawValue)

        do {
            if FileManager.default.fileExists(atPath: modelPath) {
                try FileManager.default.removeItem(atPath: modelPath)
            }
            downloadStates[variant] = .notDownloaded

            // If this was the selected model, clear selection
            if selectedModel == variant {
                selectedModel = nil
                UserDefaults.standard.removeObject(forKey: userDefaultsKey)

                // Unload WhisperKit
                whisperKit = nil
            }

            #if DEBUG
            print("WhisperKitManager: Deleted model \(variant.rawValue)")
            #endif
        } catch {
            #if DEBUG
            print("WhisperKitManager: Failed to delete model \(variant.rawValue): \(error)")
            #endif
        }
    }

    // MARK: - WhisperKit Loading

    func loadWhisperKit() async {
        guard let model = selectedModel else {
            whisperKit = nil
            return
        }

        guard downloadStates[model] == .downloaded else {
            #if DEBUG
            print("WhisperKitManager: Cannot load model \(model.rawValue) - not downloaded")
            #endif
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            whisperKit = try await WhisperKit(model: model.rawValue)

            #if DEBUG
            print("WhisperKitManager: Loaded WhisperKit with model \(model.rawValue)")
            #endif
        } catch {
            #if DEBUG
            print("WhisperKitManager: Failed to load WhisperKit: \(error)")
            #endif
            whisperKit = nil
        }
    }

    func unloadWhisperKit() {
        whisperKit = nil
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL, language: String = "") async throws -> String {
        guard let kit = whisperKit else {
            throw WhisperKitError.modelNotLoaded
        }

        // If language is specified, use it; otherwise let Whisper detect
        // usePrefillPrompt ensures the language token is properly set
        let languageParam: String? = language.isEmpty ? nil : language

        let options = DecodingOptions(
            task: .transcribe,  // Transcribe in source language, not translate
            language: languageParam,
            usePrefillPrompt: true,  // Enforce language token for each window
            detectLanguage: language.isEmpty,  // Auto-detect if no language specified
            skipSpecialTokens: true,
            withoutTimestamps: true  // Speed up processing
        )

        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)

        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(audioBuffer: AVAudioPCMBuffer, language: String = "") async throws -> String {
        guard let kit = whisperKit else {
            throw WhisperKitError.modelNotLoaded
        }

        let languageParam: String? = language.isEmpty ? nil : language

        let options = DecodingOptions(
            task: .transcribe,
            language: languageParam,
            usePrefillPrompt: true,
            detectLanguage: language.isEmpty,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let results = try await kit.transcribe(audioArray: audioBuffer.array(), decodeOptions: options)

        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeFromSamples(_ samples: [Float], language: String = "") async throws -> String {
        guard let kit = whisperKit else {
            throw WhisperKitError.modelNotLoaded
        }

        let languageParam: String? = language.isEmpty ? nil : language

        let options = DecodingOptions(
            task: .transcribe,
            language: languageParam,
            usePrefillPrompt: true,
            detectLanguage: language.isEmpty,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)

        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum WhisperKitError: LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "WhisperKit model is not loaded"
        case .modelNotDownloaded:
            return "WhisperKit model is not downloaded"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

// MARK: - AVAudioPCMBuffer Extension

extension AVAudioPCMBuffer {
    func array() -> [Float] {
        guard let channelData = floatChannelData else { return [] }
        let frameLength = Int(self.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
