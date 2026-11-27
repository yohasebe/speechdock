import SwiftUI

/// Displays character and word count for panel text areas
struct TextCountView: View {
    let text: String

    private var charCount: Int {
        text.count
    }

    private var wordCount: Int {
        TextStatistics.wordCount(text)
    }

    var body: some View {
        Text("\(charCount) \(NSLocalizedString("chars", comment: "Character count label")) / \(wordCount) \(NSLocalizedString("words", comment: "Word count label"))")
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize()
    }
}
