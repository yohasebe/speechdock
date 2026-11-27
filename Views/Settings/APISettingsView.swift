import SwiftUI

struct APISettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("SpeechDock works without API keys using macOS built-in STT/TTS. Cloud providers below are optional and offer additional voices, models, and languages.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Each field takes the key itself or a 1Password reference (op://vault/item/field). A reference is read with the 1Password CLI (op) when Settings opens or a key is first needed; only the reference is stored in the keychain.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } header: {
                Text("About API Keys")
            }
            ForEach(STTProvider.allCases) { provider in
                APIKeySection(provider: provider)
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible)
        .padding()
        .task {
            // Opening Settings reads every 1Password reference at once (one approval).
            await APIKeyManager.shared.prepareReferences()
        }
    }
}

struct APIKeySection: View {
    let provider: STTProvider

    @State private var apiKey: String = ""
    /// What the keychain holds for this provider, to tell an edited field from the saved one.
    @State private var savedValue: String = ""
    @State private var showKey: Bool = false
    @State private var isSaving: Bool = false
    @State private var isValidating: Bool = false
    @State private var saveMessage: String?
    @State private var saveMessageColor: Color = .green

    private let apiKeyManager = APIKeyManager.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Group {
                        if showKey {
                            TextField("API Key", text: $apiKey)
                        } else {
                            SecureField("API Key", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    // The value being checked is saved when the check ends; edits meanwhile would be lost.
                    .disabled(isValidating || isSaving)
                    .onSubmit {
                        guard canSave else { return }
                        Task { await saveAPIKey() }
                    }

                    Button(action: { showKey.toggle() }) {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showKey ? "Hide Key" : "Show Key")
                    .accessibilityLabel(showKey ? "Hide Key" : "Show Key")
                }

                // Status on its own rows, so long variable names and reasons
                // are not squeezed beside the buttons.
                keySourceBadge

                HStack {
                    Spacer()

                    if isValidating {
                        ProgressView()
                            .controlSize(.small)
                        Text("Validating...")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else if let message = saveMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundColor(saveMessageColor)
                    }

                    Button(SecretReference.isReference(apiKey) ? "Save Reference" : "Save to Keychain") {
                        Task {
                            await saveAPIKey()
                        }
                    }
                    .disabled(!canSave)

                    if case .failed = apiKeyManager.keyStatus(for: provider) {
                        Button("Reload from 1Password") {
                            Task { await apiKeyManager.reloadReference(for: provider) }
                        }
                    }

                    if apiKeyManager.apiKeySource(for: provider) == .keychain {
                        Button("Remove") {
                            removeAPIKey()
                        }
                        .disabled(isValidating || isSaving)
                        .foregroundColor(.red)
                    }
                }
            }
        } header: {
            Text(provider.rawValue)
        } footer: {
            Text(provider.footerDescription)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .onAppear {
            loadAPIKey()
        }
    }

    @ViewBuilder
    private var keySourceBadge: some View {
        let origin = apiKeyManager.keyOrigin(for: provider)

        VStack(alignment: .leading, spacing: 4) {
            switch origin?.source ?? .none {
            // Where the key comes from is information, not a warning: a provider
            // without a key is optional.
            case .environment:
                Label(environmentLabel(origin), systemImage: "terminal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .keychain:
                // A saved reference is described by its 1Password status below.
                if origin?.isReference != true {
                    Label("From Keychain", systemImage: "key")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .none:
                Label("Not Set", systemImage: "minus.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if origin?.isReference == true {
                referenceStatus
            }
        }
    }

    /// The variable the key came from; an older name is marked as such.
    private func environmentLabel(_ origin: APIKeyManager.KeyOrigin?) -> String {
        guard let origin else { return NSLocalizedString("From Environment", comment: "API key source") }
        if origin.isLegacyName {
            return String(format: NSLocalizedString("From Environment (%@, older name)", comment: "API key source: variable name"), origin.name)
        }
        return String(format: NSLocalizedString("From Environment (%@)", comment: "API key source: variable name"), origin.name)
    }

    /// The reference's state, by reason only; the reference text is not shown here.
    @ViewBuilder
    private var referenceStatus: some View {
        switch apiKeyManager.keyStatus(for: provider) {
        case .ready:
            Label("1Password reference: read", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundColor(.green)
        case .pending:
            Label("1Password reference: read when first used", systemImage: "clock")
                .font(.callout)
                .foregroundColor(.secondary)
        case .failed(let failure):
            Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundColor(.orange)
        case .notSet:
            EmptyView()
        }
    }

    private func loadAPIKey() {
        // The stored text: the key, or a 1Password reference (never its value).
        savedValue = apiKeyManager.storedKeychainValue(for: provider) ?? ""
        apiKey = savedValue
    }

    /// Something new to save: not empty, not what is already saved, and not busy.
    private var canSave: Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // A reference is compared without the quotes it is saved without.
        let value = SecretReference.isReference(trimmed) ? SecretReference.normalized(trimmed) : trimmed
        return !value.isEmpty && value != savedValue && !isSaving && !isValidating
    }

    private func saveAPIKey() async {
        isValidating = true
        saveMessage = nil

        var trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: ValidationResult
        if SecretReference.isReference(trimmed) {
            trimmed = SecretReference.normalized(trimmed)
            result = await validateReference(trimmed)
        } else {
            result = await APIKeyValidator.validate(key: trimmed, for: provider)
        }
        isValidating = false

        switch result {
        case .valid:
            isSaving = true
            do {
                try apiKeyManager.setAPIKey(trimmed, for: provider)
                apiKey = trimmed
                savedValue = trimmed
                saveMessageColor = .green
                saveMessage = NSLocalizedString("Valid ✓ Saved!", comment: "API key saved")
            } catch {
                saveMessageColor = .red
                saveMessage = String(format: NSLocalizedString("Error: %@", comment: "API key error"), error.localizedDescription)
            }
            isSaving = false

        case .invalid(let reason):
            saveMessageColor = .red
            saveMessage = reason

        case .networkError:
            isSaving = true
            do {
                try apiKeyManager.setAPIKey(trimmed, for: provider)
                apiKey = trimmed
                savedValue = trimmed
                saveMessageColor = .orange
                saveMessage = NSLocalizedString("Could not verify (saved anyway)", comment: "API key saved without validation")
            } catch {
                saveMessageColor = .red
                saveMessage = String(format: NSLocalizedString("Error: %@", comment: "API key error"), error.localizedDescription)
            }
            isSaving = false
        }

        // A failure stays until the next attempt, so its reason can be read.
        if saveMessageColor != .red {
            let shown = saveMessage
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if saveMessage == shown { saveMessage = nil }
            }
        }
    }

    /// Reads the reference with `op read` and validates the value it gives.
    /// Only the reference is saved; the value stays in memory.
    private func validateReference(_ reference: String) async -> ValidationResult {
        guard SecretReference.isWellFormed(reference) else {
            return .invalid(NSLocalizedString("Use the form op://vault/item/field", comment: "1Password reference format"))
        }
        switch await apiKeyManager.readReference(reference) {
        case .success(let value):
            return await APIKeyValidator.validate(key: value, for: provider)
        case .failure(let failure):
            return .invalid(failure.localizedDescription)
        }
    }

    private func removeAPIKey() {
        do {
            try apiKeyManager.deleteAPIKey(for: provider)
            apiKey = ""
            savedValue = ""
            saveMessageColor = .green
            let shown = NSLocalizedString("Removed", comment: "API key removed")
            saveMessage = shown
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if saveMessage == shown { saveMessage = nil }
            }
        } catch {
            saveMessageColor = .red
            saveMessage = String(format: NSLocalizedString("Error: %@", comment: "API key error"), error.localizedDescription)
        }
    }
}
