import SwiftUI

struct TextReplacementSettingsView: View {
    @StateObject private var service = TextReplacementService.shared
    @State private var selectedRuleIDs: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Built-in Patterns Section
                builtInPatternsSection

                Divider()

                // Custom Rules Section
                customRulesSection
            }
            .padding()
        }
    }

    // MARK: - Built-in Patterns Section

    private var builtInPatternsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-in Patterns")
                .font(.headline)

            Text("Automatically replace common patterns like URLs and emails.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                ForEach(BuiltInPattern.allCases, id: \.self) { pattern in
                    BuiltInPatternRowView(pattern: pattern, service: service)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - Custom Rules Section

    private var customRulesSection: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Rules table
            if service.rules.isEmpty {
                emptyStateView
            } else {
                rulesListView
            }

            // Footer with buttons
            footerView
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Custom Rules")
                .font(.headline)

            Spacer()

            Text("\(service.rules.count) rules")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 24))
                .foregroundColor(.secondary)

            Text("No custom rules")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Add rules for specific text replacements.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Rules List

    private var rulesListView: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 8) {
                // Spacer for toggle
                Spacer()
                    .frame(width: 50)

                Text("Find")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Replace With")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Spacer for delete button
                Spacer()
                    .frame(width: 30)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Scrollable list
            LazyVStack(spacing: 4) {
                ForEach(service.rules) { rule in
                    RuleRowView(
                        rule: rule,
                        onUpdate: { updatedRule in
                            service.updateRule(updatedRule)
                        },
                        onDelete: {
                            if let index = service.rules.firstIndex(where: { $0.id == rule.id }) {
                                service.removeRule(at: index)
                            }
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Add button
            Button(action: { service.addRule() }) {
                Label("Add", systemImage: "plus")
            }

            Spacer()

            // Import/Export buttons
            Button("Import...") {
                service.importRules(merge: true)
            }

            Button("Export...") {
                service.exportRules()
            }
            .disabled(service.rules.isEmpty)
        }
        .padding(.top, 8)
    }
}

// MARK: - Rule Row View

struct RuleRowView: View {
    let rule: TextReplacementRule
    let onUpdate: (TextReplacementRule) -> Void
    let onDelete: () -> Void

    @State private var findText: String
    @State private var replaceText: String
    @State private var isEnabled: Bool

    init(rule: TextReplacementRule, onUpdate: @escaping (TextReplacementRule) -> Void, onDelete: @escaping () -> Void) {
        self.rule = rule
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self._findText = State(initialValue: rule.find)
        self._replaceText = State(initialValue: rule.replace)
        self._isEnabled = State(initialValue: rule.isEnabled)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Enable toggle
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    var updated = rule
                    updated.isEnabled = newValue
                    onUpdate(updated)
                }

            // Find text field
            TextField("Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onChange(of: findText) { _, newValue in
                    var updated = rule
                    updated.find = newValue
                    onUpdate(updated)
                }

            // Replace text field
            TextField("Replace", text: $replaceText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onChange(of: replaceText) { _, newValue in
                    var updated = rule
                    updated.replace = newValue
                    onUpdate(updated)
                }

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete rule")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Built-in Pattern Row View

struct BuiltInPatternRowView: View {
    let pattern: BuiltInPattern
    @ObservedObject var service: TextReplacementService

    @State private var isEnabled: Bool
    @State private var replacement: String

    init(pattern: BuiltInPattern, service: TextReplacementService) {
        self.pattern = pattern
        self.service = service
        self._isEnabled = State(initialValue: service.isBuiltInPatternEnabled(pattern))
        self._replacement = State(initialValue: service.builtInPatternReplacement(pattern))
    }

    var body: some View {
        HStack(spacing: 8) {
            // Enable toggle
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    service.setBuiltInPatternEnabled(pattern, enabled: newValue)
                }

            // Pattern name
            Text(pattern.displayName)
                .frame(width: 120, alignment: .leading)

            // Arrow indicator
            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)
                .font(.caption)

            // Replacement text field
            TextField("Replacement", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onChange(of: replacement) { _, newValue in
                    service.setBuiltInPatternReplacement(pattern, replacement: newValue)
                }

            // Reset button
            Button(action: {
                replacement = pattern.defaultReplacement
                service.setBuiltInPatternReplacement(pattern, replacement: pattern.defaultReplacement)
            }) {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TextReplacementSettingsView()
        .frame(width: 500, height: 500)
}
