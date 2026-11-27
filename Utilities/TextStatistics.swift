import NaturalLanguage

/// Counts shown for panel text and kept with saved transcriptions.
enum TextStatistics {
    /// The words the system's tokenizer finds, so that text written without
    /// spaces, such as Japanese or Chinese, is counted by word too.
    static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}
