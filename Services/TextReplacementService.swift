import Foundation
import AppKit

/// A text replacement rule
struct TextReplacementRule: Identifiable, Codable, Equatable {
    var id: UUID
    var find: String
    var replace: String
    var isEnabled: Bool

    init(id: UUID = UUID(), find: String = "", replace: String = "", isEnabled: Bool = true) {
        self.id = id
        self.find = find
        self.replace = replace
        self.isEnabled = isEnabled
    }
}

/// Built-in pattern types for automatic replacement
enum BuiltInPattern: String, CaseIterable, Codable {
    case url = "url"
    case email = "email"
    case filePath = "filePath"

    var displayName: String {
        switch self {
        case .url: return NSLocalizedString("URLs", comment: "Built-in pattern")
        case .email: return NSLocalizedString("Email Addresses", comment: "Built-in pattern")
        case .filePath: return NSLocalizedString("File Paths", comment: "Built-in pattern")
        }
    }

    var defaultReplacement: String {
        switch self {
        case .url: return " URL "
        case .email: return " Email "
        case .filePath: return " Path "
        }
    }

    /// Regex pattern for matching
    var regex: NSRegularExpression? {
        let pattern: String
        switch self {
        case .url:
            // Matches http://, https://, ftp:// URLs
            pattern = #"https?://[^\s<>\"\'\)\]]+|ftp://[^\s<>\"\'\)\]]+"#
        case .email:
            // Matches email addresses
            pattern = #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#
        case .filePath:
            // Matches Unix-style paths (/path/to/file) and Windows-style paths (C:\path\to\file)
            pattern = #"(?:/[^\s:*?\"<>|]+(?:/[^\s:*?\"<>|]+)+)|(?:[A-Za-z]:\\[^\s:*?\"<>|]+(?:\\[^\s:*?\"<>|]+)*)"#
        }

        return try? NSRegularExpression(pattern: pattern, options: [])
    }
}

/// Settings for a built-in pattern
struct BuiltInPatternSetting: Codable, Equatable {
    var isEnabled: Bool
    var replacement: String

    init(isEnabled: Bool = false, replacement: String = "") {
        self.isEnabled = isEnabled
        self.replacement = replacement
    }
}

/// Export data structure containing both custom rules and built-in pattern settings
struct TextReplacementExportData: Codable {
    var customRules: [TextReplacementRule]
    var builtInPatterns: [String: BuiltInPatternSetting]

    init(customRules: [TextReplacementRule], builtInPatterns: [BuiltInPattern: BuiltInPatternSetting]) {
        self.customRules = customRules
        // Convert enum keys to strings for JSON encoding
        self.builtInPatterns = builtInPatterns.reduce(into: [:]) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
    }
}

/// A match found in text that will be replaced
struct TextReplacementMatch {
    let range: NSRange
    let originalText: String
    let replacementText: String
}

/// Service for managing text replacement rules
@MainActor
final class TextReplacementService: ObservableObject {
    static let shared = TextReplacementService()

    @Published private(set) var rules: [TextReplacementRule] = []
    @Published private(set) var builtInSettings: [BuiltInPattern: BuiltInPatternSetting] = [:]

    private let storageKey = "textReplacementRules"
    private let builtInStorageKey = "textReplacementBuiltInPatterns"
    private let fileManager = FileManager.default

    private init() {
        loadRules()
        loadBuiltInSettings()
    }

    // MARK: - Built-in Pattern Management

    func isBuiltInPatternEnabled(_ pattern: BuiltInPattern) -> Bool {
        builtInSettings[pattern]?.isEnabled ?? false
    }

    func builtInPatternReplacement(_ pattern: BuiltInPattern) -> String {
        builtInSettings[pattern]?.replacement ?? pattern.defaultReplacement
    }

    func setBuiltInPatternEnabled(_ pattern: BuiltInPattern, enabled: Bool) {
        if builtInSettings[pattern] == nil {
            builtInSettings[pattern] = BuiltInPatternSetting(
                isEnabled: enabled,
                replacement: pattern.defaultReplacement
            )
        } else {
            builtInSettings[pattern]?.isEnabled = enabled
        }
        saveBuiltInSettings()
    }

    func setBuiltInPatternReplacement(_ pattern: BuiltInPattern, replacement: String) {
        if builtInSettings[pattern] == nil {
            builtInSettings[pattern] = BuiltInPatternSetting(
                isEnabled: false,
                replacement: replacement
            )
        } else {
            builtInSettings[pattern]?.replacement = replacement
        }
        saveBuiltInSettings()
    }

    // MARK: - Rule Management

    func addRule(_ rule: TextReplacementRule = TextReplacementRule()) {
        rules.append(rule)
        saveRules()
    }

    func removeRule(at index: Int) {
        guard index >= 0 && index < rules.count else { return }
        rules.remove(at: index)
        saveRules()
    }

    func removeRules(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        saveRules()
    }

    func updateRule(_ rule: TextReplacementRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
            saveRules()
        }
    }

    func moveRules(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        saveRules()
    }

    // MARK: - Text Replacement

    /// Apply all enabled replacement rules to the given text
    func applyReplacements(to text: String) -> String {
        var result = text

        // Apply built-in pattern replacements first
        result = applyBuiltInPatternReplacements(to: result)

        // Then apply custom rules
        for rule in rules where rule.isEnabled && !rule.find.isEmpty {
            result = result.replacingOccurrences(of: rule.find, with: rule.replace)
        }

        return result
    }

    /// Apply built-in pattern replacements using regex
    private func applyBuiltInPatternReplacements(to text: String) -> String {
        var result = text

        for pattern in BuiltInPattern.allCases {
            guard isBuiltInPatternEnabled(pattern),
                  let regex = pattern.regex else { continue }

            let replacement = builtInPatternReplacement(pattern)
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }

        return result
    }

    /// Find all matches in the text and return their ranges with replacement info
    func findMatches(in text: String) -> [TextReplacementMatch] {
        var matches: [TextReplacementMatch] = []
        let nsString = text as NSString

        // Find built-in pattern matches first
        for pattern in BuiltInPattern.allCases {
            guard isBuiltInPatternEnabled(pattern),
                  let regex = pattern.regex else { continue }

            let replacement = builtInPatternReplacement(pattern)
            let fullRange = NSRange(location: 0, length: nsString.length)

            regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
                guard let matchRange = result?.range else { return }
                let originalText = nsString.substring(with: matchRange)

                matches.append(TextReplacementMatch(
                    range: matchRange,
                    originalText: originalText,
                    replacementText: replacement
                ))
            }
        }

        // Find custom rule matches
        for rule in rules where rule.isEnabled && !rule.find.isEmpty {
            var searchRange = NSRange(location: 0, length: nsString.length)

            while searchRange.location < nsString.length {
                let foundRange = nsString.range(of: rule.find, options: [], range: searchRange)

                if foundRange.location == NSNotFound {
                    break
                }

                matches.append(TextReplacementMatch(
                    range: foundRange,
                    originalText: rule.find,
                    replacementText: rule.replace
                ))

                // Move search range past this match
                searchRange.location = foundRange.location + foundRange.length
                searchRange.length = nsString.length - searchRange.location
            }
        }

        // Sort by location
        matches.sort { $0.range.location < $1.range.location }

        return matches
    }

    // MARK: - Persistence

    private func loadRules() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            rules = []
            return
        }

        do {
            rules = try JSONDecoder().decode([TextReplacementRule].self, from: data)
        } catch {
            dprint("TextReplacementService: Failed to load rules: \(error)")

            rules = []
        }
    }

    private func saveRules() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            dprint("TextReplacementService: Failed to save rules: \(error)")

        }
    }

    private func loadBuiltInSettings() {
        guard let data = UserDefaults.standard.data(forKey: builtInStorageKey) else {
            // Initialize with defaults
            builtInSettings = [:]
            return
        }

        do {
            let decoded = try JSONDecoder().decode([String: BuiltInPatternSetting].self, from: data)
            builtInSettings = [:]
            for (key, value) in decoded {
                if let pattern = BuiltInPattern(rawValue: key) {
                    builtInSettings[pattern] = value
                }
            }
        } catch {
            dprint("TextReplacementService: Failed to load built-in settings: \(error)")

            builtInSettings = [:]
        }
    }

    private func saveBuiltInSettings() {
        let encoded: [String: BuiltInPatternSetting] = builtInSettings.reduce(into: [:]) { result, pair in
            result[pair.key.rawValue] = pair.value
        }

        do {
            let data = try JSONEncoder().encode(encoded)
            UserDefaults.standard.set(data, forKey: builtInStorageKey)
        } catch {
            dprint("TextReplacementService: Failed to save built-in settings: \(error)")

        }
    }

    // MARK: - Export / Import

    /// Export rules and built-in pattern settings to a JSON file
    func exportRules() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "TextReplacementRules.json"
        savePanel.title = NSLocalizedString("Export Text Replacement Rules", comment: "Export save panel title")
        savePanel.message = NSLocalizedString("Choose a location to save the rules", comment: "Export save panel message")

        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self = self else { return }

            do {
                let exportData = TextReplacementExportData(
                    customRules: self.rules,
                    builtInPatterns: self.builtInSettings
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(exportData)
                try data.write(to: url)
                dprint("TextReplacementService: Exported \(self.rules.count) rules and \(self.builtInSettings.count) built-in settings to \(url.path)")

            } catch {
                dprint("TextReplacementService: Failed to export rules: \(error)")

            }
        }
    }

    /// Import rules and built-in pattern settings from a JSON file (merges with existing)
    func importRules(merge: Bool = true) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.title = NSLocalizedString("Import Text Replacement Rules", comment: "Import open panel title")
        openPanel.message = NSLocalizedString("Select a JSON file to import", comment: "Import open panel message")

        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url, let self = self else { return }

            do {
                let data = try Data(contentsOf: url)

                // Try new format first (with built-in patterns)
                if let exportData = try? JSONDecoder().decode(TextReplacementExportData.self, from: data) {
                    self.importExportData(exportData, merge: merge)
                    return
                }

                // Fall back to old format (just rules array) for backward compatibility
                let importedRules = try JSONDecoder().decode([TextReplacementRule].self, from: data)
                self.importCustomRules(importedRules, merge: merge)

            } catch {
                dprint("TextReplacementService: Failed to import rules: \(error)")

            }
        }
    }

    /// Import from new export format (with built-in patterns)
    private func importExportData(_ exportData: TextReplacementExportData, merge: Bool) {
        // Import custom rules
        importCustomRules(exportData.customRules, merge: merge)

        // Import built-in pattern settings
        for (key, setting) in exportData.builtInPatterns {
            if let pattern = BuiltInPattern(rawValue: key) {
                builtInSettings[pattern] = setting
            }
        }
        saveBuiltInSettings()
        dprint("TextReplacementService: Imported \(exportData.customRules.count) rules and \(exportData.builtInPatterns.count) built-in settings")

    }

    /// Import custom rules only
    private func importCustomRules(_ importedRules: [TextReplacementRule], merge: Bool) {
        if merge {
            // Merge: add imported rules that don't already exist (by find text)
            let existingFinds = Set(self.rules.map { $0.find })
            for var rule in importedRules {
                if !existingFinds.contains(rule.find) {
                    rule.id = UUID() // Assign new ID to avoid conflicts
                    self.rules.append(rule)
                }
            }
        } else {
            // Replace: clear existing rules and use imported ones
            self.rules = importedRules.map { rule in
                var newRule = rule
                newRule.id = UUID() // Assign new IDs
                return newRule
            }
        }

        self.saveRules()
        dprint("TextReplacementService: Imported \(importedRules.count) custom rules")

    }

    /// Clear all rules
    func clearAllRules() {
        rules.removeAll()
        saveRules()
    }
}
