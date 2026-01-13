import SwiftUI

struct APISettingsView: View {
    var body: some View {
        Form {
            ForEach(STTProvider.allCases) { provider in
                APIKeySection(provider: provider)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct APIKeySection: View {
    let provider: STTProvider

    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveMessage: String?

    private let apiKeyManager = APIKeyManager.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if showKey {
                        TextField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                    }

                    Button(action: { showKey.toggle() }) {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    keySourceBadge

                    Spacer()

                    if let message = saveMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(message.contains("Error") ? .red : .green)
                    }

                    Button("Save to Keychain") {
                        saveAPIKey()
                    }
                    .disabled(apiKey.isEmpty || isSaving)

                    if apiKeyManager.apiKeySource(for: provider) == .keychain {
                        Button("Remove") {
                            removeAPIKey()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
        } header: {
            Text(provider.rawValue)
        }
        .onAppear {
            loadAPIKey()
        }
    }

    @ViewBuilder
    private var keySourceBadge: some View {
        let source = apiKeyManager.apiKeySource(for: provider)

        switch source {
        case .environment:
            Label("From Environment", systemImage: "terminal")
                .font(.caption)
                .foregroundColor(.blue)
        case .keychain:
            Label("From Keychain", systemImage: "key.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .none:
            Label("Not Set", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    private func loadAPIKey() {
        if apiKeyManager.apiKeySource(for: provider) == .keychain {
            apiKey = apiKeyManager.getAPIKey(for: provider) ?? ""
        } else {
            apiKey = ""
        }
    }

    private func saveAPIKey() {
        isSaving = true
        saveMessage = nil

        do {
            try apiKeyManager.setAPIKey(apiKey, for: provider)
            saveMessage = "Saved!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                saveMessage = nil
            }
        } catch {
            saveMessage = "Error: \(error.localizedDescription)"
        }

        isSaving = false
    }

    private func removeAPIKey() {
        do {
            try apiKeyManager.deleteAPIKey(for: provider)
            apiKey = ""
            saveMessage = "Removed"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                saveMessage = nil
            }
        } catch {
            saveMessage = "Error: \(error.localizedDescription)"
        }
    }
}
