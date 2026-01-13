import SwiftUI

/// Settings view for WhisperKit model management
struct WhisperKitSettingsView: View {
    @StateObject private var whisperKitManager = WhisperKitManager.shared

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Text("Download and manage WhisperKit models for offline speech recognition. Larger models provide better accuracy but require more storage and processing time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Local Whisper Models")
                }

                Section {
                    ForEach(WhisperModelVariant.allCases) { variant in
                        WhisperModelRow(
                            variant: variant,
                            downloadState: whisperKitManager.downloadStates[variant] ?? .notDownloaded,
                            isSelected: whisperKitManager.selectedModel == variant,
                            onDownload: { whisperKitManager.downloadModel(variant) },
                            onCancel: { whisperKitManager.cancelDownload(variant) },
                            onDelete: { whisperKitManager.deleteModel(variant) },
                            onSelect: { whisperKitManager.selectModel(variant) }
                        )
                    }
                } header: {
                    Text("Available Models")
                }

                Section {
                    HStack {
                        Text("Selected Model")
                        Spacer()
                        if let selected = whisperKitManager.selectedModel {
                            Text(selected.displayName)
                                .foregroundColor(.secondary)
                        } else {
                            Text("None")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Status")
                        Spacer()
                        if whisperKitManager.isLoading {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Loading...")
                            }
                            .foregroundColor(.secondary)
                        } else if whisperKitManager.whisperKit != nil {
                            Text("Ready")
                                .foregroundColor(.green)
                        } else if whisperKitManager.selectedModel != nil {
                            Text("Select a downloaded model")
                                .foregroundColor(.orange)
                        } else {
                            Text("Download and select a model")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Model Status")
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .onAppear {
            Task {
                await whisperKitManager.refreshModelStates()
            }
        }
    }
}

/// Row for a single WhisperKit model
struct WhisperModelRow: View {
    let variant: WhisperModelVariant
    let downloadState: ModelDownloadState
    let isSelected: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(variant.displayName)
                        .fontWeight(isSelected ? .semibold : .regular)

                    if variant.isRecommended {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }

                Text(variant.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Action buttons based on state
            switch downloadState {
            case .notDownloaded:
                Button("Download") {
                    onDownload()
                }
                .buttonStyle(.bordered)

            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)

                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)

                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }

            case .downloaded:
                HStack(spacing: 8) {
                    if !isSelected {
                        Button("Select") {
                            onSelect()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }

            case .error(let message):
                HStack(spacing: 8) {
                    Text("Error")
                        .font(.caption)
                        .foregroundColor(.red)
                        .help(message)

                    Button("Retry") {
                        onDownload()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
