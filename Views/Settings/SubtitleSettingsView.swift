import SwiftUI

struct SubtitleSettingsView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                Toggle(isOn: $appState.subtitleModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Subtitle Mode")
                        Text("Display real-time transcription as subtitles during recording.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Subtitle Mode")
            }

            Section {
                Picker("Position", selection: $appState.subtitlePosition) {
                    ForEach(SubtitlePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(appState.subtitleFontSize)) pt")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    HStack(spacing: 8) {
                        Slider(
                            value: $appState.subtitleFontSize,
                            in: 18...48,
                            step: 2
                        ) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("A")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        } maximumValueLabel: {
                            Text("A")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                        }

                        Button("Reset") {
                            appState.subtitleFontSize = 28.0
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Text Opacity")
                        Spacer()
                        Text("\(Int(appState.subtitleOpacity * 100))%")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    Slider(
                        value: $appState.subtitleOpacity,
                        in: 0.3...1.0,
                        step: 0.05
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Background Opacity")
                        Spacer()
                        Text("\(Int(appState.subtitleBackgroundOpacity * 100))%")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    Slider(
                        value: $appState.subtitleBackgroundOpacity,
                        in: 0.1...0.9,
                        step: 0.05
                    )
                }

                Picker("Max Lines", selection: $appState.subtitleMaxLines) {
                    ForEach(2...6, id: \.self) { lines in
                        Text("\(lines) lines").tag(lines)
                    }
                }

                Toggle(isOn: $appState.subtitleHidePanelWhenActive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide STT Panel when active")
                        Text("Temporarily hide the STT panel when subtitle mode is active.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Appearance")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        appState.subtitleModeEnabled = false
                        appState.subtitlePosition = .bottom
                        appState.subtitleFontSize = 28.0
                        appState.subtitleOpacity = 0.85
                        appState.subtitleBackgroundOpacity = 0.5
                        appState.subtitleMaxLines = 3
                        appState.subtitleHidePanelWhenActive = true
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}
