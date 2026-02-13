import Foundation

/// A single transcription history entry
struct TranscriptionHistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let provider: String
    let text: String
    let wordCount: Int

    /// Short preview text for menu display (first 40 characters)
    var preview: String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= 40 {
            return cleaned
        }
        return String(cleaned.prefix(40)) + "..."
    }

    /// Formatted date string for display
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Manages transcription history persistence using JSON file in Application Support
@MainActor
final class TranscriptionHistoryService {
    static let shared = TranscriptionHistoryService()

    private let maxEntries = 50
    private let fileName = "transcription_history.json"
    private var entries: [TranscriptionHistoryEntry] = []

    private init() {
        loadHistory()
    }

    /// Get all history entries (newest first)
    var allEntries: [TranscriptionHistoryEntry] {
        entries
    }

    /// Add a new transcription to history
    func addEntry(text: String, provider: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let wordCount = trimmed.split(omittingEmptySubsequences: true) { $0.isWhitespace || $0.isNewline }.count

        let entry = TranscriptionHistoryEntry(
            id: UUID(),
            date: Date(),
            provider: provider,
            text: trimmed,
            wordCount: wordCount
        )

        entries.insert(entry, at: 0)

        // Enforce max entries (FIFO)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        saveHistory()
    }

    /// Clear all history
    func clearHistory() {
        entries.removeAll()
        saveHistory()
    }

    // MARK: - Persistence

    private var historyFileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = appSupport.appendingPathComponent("SpeechDock", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        return appDir.appendingPathComponent(fileName)
    }

    private func loadHistory() {
        guard let url = historyFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data)
            #if DEBUG
            print("TranscriptionHistoryService: Loaded \(entries.count) entries")
            #endif
        } catch {
            #if DEBUG
            print("TranscriptionHistoryService: Failed to load history: \(error)")
            #endif
        }
    }

    private func saveHistory() {
        guard let url = historyFileURL else { return }

        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            print("TranscriptionHistoryService: Failed to save history: \(error)")
            #endif
        }
    }
}
