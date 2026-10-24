import Foundation
import UniformTypeIdentifiers

/// Shared by validation, file chooser, drag destinations, and format guidance.
enum AudioFileSupport {
    static let extensions = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "webm", "ogg", "flac", "mp4"]
    /// OpenAI's transcription API rejects these as an unsupported file format
    private static let openAIUnsupported: Set<String> = ["aac", "aiff", "aif"]
    static func extensions(for provider: RealtimeSTTProvider) -> [String] {
        provider == .openAI ? extensions.filter { !openAIUnsupported.contains($0) } : extensions
    }
    static func contentTypes(for provider: RealtimeSTTProvider) -> [UTType] {
        extensions(for: provider).compactMap { UTType(filenameExtension: $0) }
    }
    static func formatHint(for provider: RealtimeSTTProvider) -> String {
        extensions(for: provider).map { $0.uppercased() }.joined(separator: ", ")
    }
    static func accepts(_ url: URL, for provider: RealtimeSTTProvider) -> Bool {
        extensions(for: provider).contains(url.pathExtension.lowercased())
    }
    static func limits(for provider: RealtimeSTTProvider) -> String {
        if provider == .macOS {
            return NSLocalizedString("Maximum 100 MB · No duration limit", comment: "Local audio file limits")
        }
        return String(format: NSLocalizedString("Maximum %d MB · Duration: %@", comment: "Audio file limits"), provider.maxFileSizeMB, NSLocalizedString(provider.maxAudioDuration, comment: "Audio duration limit"))
    }
}
