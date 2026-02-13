import SwiftUI

/// Displays character and word count for panel text areas
struct TextCountView: View {
    let text: String

    private var charCount: Int {
        text.count
    }

    private var wordCount: Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(omittingEmptySubsequences: true) { $0.isWhitespace || $0.isNewline }.count
    }

    var body: some View {
        Text("\(charCount) \(NSLocalizedString("chars", comment: "Character count label")) / \(wordCount) \(NSLocalizedString("words", comment: "Word count label"))")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize()
    }
}
