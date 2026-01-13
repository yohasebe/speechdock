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

    private let storageKey = "textReplacementRules"
    private let fileManager = FileManager.default

    private init() {
        loadRules()
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

        for rule in rules where rule.isEnabled && !rule.find.isEmpty {
            result = result.replacingOccurrences(of: rule.find, with: rule.replace)
        }

        return result
    }

    /// Find all matches in the text and return their ranges with replacement info
    func findMatches(in text: String) -> [TextReplacementMatch] {
        var matches: [TextReplacementMatch] = []
        let nsString = text as NSString

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
            #if DEBUG
            print("TextReplacementService: Failed to load rules: \(error)")
            #endif
            rules = []
        }
    }

    private func saveRules() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            #if DEBUG
            print("TextReplacementService: Failed to save rules: \(error)")
            #endif
        }
    }

    // MARK: - Export / Import

    /// Export rules to a JSON file
    func exportRules() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "TextReplacementRules.json"
        savePanel.title = "Export Text Replacement Rules"
        savePanel.message = "Choose a location to save the rules"

        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self = self else { return }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(self.rules)
                try data.write(to: url)

                #if DEBUG
                print("TextReplacementService: Exported \(self.rules.count) rules to \(url.path)")
                #endif
            } catch {
                #if DEBUG
                print("TextReplacementService: Failed to export rules: \(error)")
                #endif
            }
        }
    }

    /// Import rules from a JSON file (merges with existing rules)
    func importRules(merge: Bool = true) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Import Text Replacement Rules"
        openPanel.message = "Select a JSON file to import"

        openPanel.begin { [weak self] response in
            guard response == .OK, let url = openPanel.url, let self = self else { return }

            do {
                let data = try Data(contentsOf: url)
                let importedRules = try JSONDecoder().decode([TextReplacementRule].self, from: data)

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

                #if DEBUG
                print("TextReplacementService: Imported \(importedRules.count) rules from \(url.path)")
                #endif
            } catch {
                #if DEBUG
                print("TextReplacementService: Failed to import rules: \(error)")
                #endif
            }
        }
    }

    /// Clear all rules
    func clearAllRules() {
        rules.removeAll()
        saveRules()
    }
}
