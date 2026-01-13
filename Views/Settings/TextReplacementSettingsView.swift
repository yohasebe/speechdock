import SwiftUI

struct TextReplacementSettingsView: View {
    @StateObject private var service = TextReplacementService.shared
    @State private var selectedRuleIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Rules table
            if service.rules.isEmpty {
                emptyStateView
            } else {
                rulesListView
            }

            Divider()

            // Footer with buttons
            footerView
        }
        .padding()
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Text Replacement Rules")
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
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "text.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("No replacement rules")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Add rules to automatically replace text in STT transcriptions.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Add Rule") {
                service.addRule()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rules List

    private var rulesListView: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 8) {
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

                // Spacer for toggle and delete button
                Spacer()
                    .frame(width: 70)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Scrollable list
            ScrollView {
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
            .frame(minHeight: 200, maxHeight: 300)
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

            // Enable toggle
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    var updated = rule
                    updated.isEnabled = newValue
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

#Preview {
    TextReplacementSettingsView()
        .frame(width: 500, height: 400)
}
