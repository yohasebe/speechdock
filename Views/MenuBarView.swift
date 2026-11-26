import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // App title and status
            HStack {
                Image(systemName: appState.isRecording ? "mic.fill" : "waveform.badge.microphone")
                    .foregroundColor(appState.isRecording ? .red : .accentColor)
                    .font(.title2)

                Text("SpeechDock")
                    .font(.headline)

                Spacer()

                // Status indicator
                if appState.isRecording {
                    Text("Recording")
                        .font(.callout)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .cornerRadius(4)
                } else if appState.transcriptionState == .processing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Processing")
                            .font(.callout)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .cornerRadius(4)
                } else if appState.ttsState == .speaking {
                    Text("Speaking")
                        .font(.callout)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .cornerRadius(4)
                } else if appState.isProcessing || appState.ttsState == .loading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Divider()
                .padding(.vertical, 4)

            // MARK: - STT Section
            Text("Speech-to-Text")
                .font(.callout)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 2)

            // Microphone permission warning
            if !appState.hasMicrophonePermission {
                permissionWarning(
                    icon: "mic.slash",
                    text: "Microphone access required",
                    action: openMicrophoneSettings
                )
            }

            // STT Action button with shortcut
            Button(action: {
                StatusBarManager.shared.closePanel()
                appState.toggleRecording()
            }) {
                HStack {
                    Image(systemName: appState.isRecording ? "stop.fill" : "record.circle")
                        .foregroundColor(appState.isRecording ? .red : (appState.hasMicrophonePermission ? .accentColor : .secondary))
                        .frame(width: 20)
                    Text(appState.isRecording ? "Stop" : "Transcription")
                        .font(.callout)
                        .foregroundColor(appState.hasMicrophonePermission ? .primary : .secondary)
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.sttKeyCombo.displayString ?? "\u{2318}\u{21E7}Space")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())
            .disabled(appState.isProcessing)

            // Subtitle mode toggle
            Button(action: {
                appState.toggleSubtitleMode()
            }) {
                HStack {
                    Image(systemName: appState.subtitleModeEnabled ? "captions.bubble.fill" : "captions.bubble")
                        .foregroundColor(appState.hasMicrophonePermission ? .accentColor : .secondary)
                        .frame(width: 20)
                    Text("Subtitle Mode")
                        .font(.callout)
                        .foregroundColor(appState.hasMicrophonePermission ? .primary : .secondary)
                    Spacer()
                    if appState.subtitleModeEnabled {
                        Text("On")
                            .font(.callout)
                            .foregroundColor(.accentColor)
                    } else {
                        Text("Off")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    shortcutBadge(appState.hotKeyService?.subtitleKeyCombo.displayString ?? "\u{2303}\u{2325}S")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())

            // Floating mic button toggle
            Button(action: {
                appState.toggleFloatingMicButton()
            }) {
                HStack {
                    Image(systemName: appState.showFloatingMicButton ? "mic.circle.fill" : "mic.circle")
                        .foregroundColor(appState.hasMicrophonePermission ? .accentColor : .secondary)
                        .frame(width: 20)
                    Text("Floating Mic Button")
                        .font(.callout)
                        .foregroundColor(appState.hasMicrophonePermission ? .primary : .secondary)
                    Spacer()
                    if appState.showFloatingMicButton {
                        Text("On")
                            .font(.callout)
                            .foregroundColor(.accentColor)
                    } else {
                        Text("Off")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    shortcutBadge(appState.hotKeyService?.quickTranscriptionKeyCombo.displayString ?? "\u{2303}\u{2325}M")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())

            // Transcribe Audio File button
            Button(action: {
                StatusBarManager.shared.closePanel()
                appState.openAudioFileForTranscription()
            }) {
                HStack {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .foregroundColor(appState.selectedRealtimeProvider.supportsFileTranscription ? .accentColor : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Transcribe Audio File...")
                            .font(.callout)
                            .foregroundColor(appState.selectedRealtimeProvider.supportsFileTranscription ? .primary : .secondary)
                        Text(appState.selectedRealtimeProvider.fileTranscriptionDescription)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())
            .disabled(appState.isRecording || appState.transcriptionState == .transcribingFile)

            // Transcription History submenu
            TranscriptionHistoryMenu(appState: appState)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 4)

            // MARK: - TTS Section
            Text("Text-to-Speech")
                .font(.callout)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 2)

            // Accessibility permission warning
            if !appState.hasAccessibilityPermission {
                permissionWarning(
                    icon: "hand.raised.slash",
                    text: "Accessibility is used to capture selected text",
                    action: openAccessibilitySettings
                )
            }

            // Screen Recording permission warning
            if !appState.hasScreenRecordingPermission {
                permissionWarning(
                    icon: "rectangle.dashed.badge.record",
                    text: "Screen Recording access recommended",
                    action: openScreenRecordingSettings
                )
            }

            // TTS Action button with shortcut
            Button(action: {
                // Capture frontmost app BEFORE closing the panel to ensure
                // we know which browser/app to copy the selected text from
                let capturedFrontmost = NSWorkspace.shared.frontmostApplication
                StatusBarManager.shared.closePanel()
                appState.startTTS(frontmostApp: capturedFrontmost)
            }) {
                HStack {
                    Image(systemName: "speaker.wave.2")
                        .foregroundColor(.accentColor)
                        .frame(width: 20)
                    Text("Text to Speech")
                        .font(.callout)
                        .foregroundColor(.primary)
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.ttsKeyCombo.displayString ?? "\u{2303}\u{2325}T")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())
            .disabled(appState.ttsState == .speaking || appState.ttsState == .loading)

            // OCR to TTS Action button with shortcut
            Button(action: {
                StatusBarManager.shared.closePanel()
                appState.startOCR()
            }) {
                let ocrEnabled = appState.hasScreenRecordingPermission
                HStack {
                    Image(systemName: "text.viewfinder")
                        .foregroundColor(ocrEnabled ? .accentColor : .secondary)
                        .frame(width: 20)
                    Text("OCR Region to TTS")
                        .font(.callout)
                        .foregroundColor(ocrEnabled ? .primary : .secondary)
                    Spacer()
                    shortcutBadge(appState.hotKeyService?.ocrKeyCombo.displayString ?? "\u{2303}\u{2325}\u{21E7}O")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarActionButtonStyle())
            .disabled(appState.ocrCoordinator.isSelecting || appState.ocrCoordinator.isProcessing)

            Divider()
                .padding(.vertical, 4)

            // MARK: - Footer Actions
            VStack(spacing: 2) {
                // Settings
                Button(action: {
                    openSettings()
                }) {
                    HStack {
                        Image(systemName: "gear")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        Text("Settings...")
                            .font(.callout)
                        Spacer()
                        shortcutBadge("\u{2318},")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarActionButtonStyle())

                Button {
                    StatusBarManager.shared.closePanel()
                    PermissionSetupController.shared.show()
                } label: {
                    HStack {
                        Image(systemName: "lock.shield").foregroundColor(.accentColor).frame(width: 20)
                        Text("Permissions...").font(.callout)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarActionButtonStyle())

                // Check for Updates
                CheckForUpdatesView()
                    .buttonStyle(MenuBarActionButtonStyle())

                // Help
                Button(action: {
                    openHelp()
                }) {
                    HStack {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        Text("Help & Documentation")
                            .font(.callout)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarActionButtonStyle())

                Divider()
                    .padding(.vertical, 4)

                // Quit
                Button(action: {
                    (NSApplication.shared.delegate as? AppDelegate)?.isExplicitQuit = true
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack {
                        Image(systemName: "power")
                            .foregroundColor(.accentColor)
                            .frame(width: 20)
                        Text("Quit SpeechDock")
                            .font(.callout)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarActionButtonStyle())
            }
        }
        .padding(6)
        .frame(width: 280)
        .onAppear {
            appState.updatePermissionStatus()
        }
    }

    // Shortcut badge view
    private func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(4)
    }

    // Permission warning view
    private func permissionWarning(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.orange)
                    .font(.callout)
                Text(LocalizedStringKey(text))  // Callers pass the English key
                    .font(.callout)
                    .foregroundColor(.orange)
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .font(.callout)
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func openMicrophoneSettings() {
        StatusBarManager.shared.closePopover()
        let service = PermissionService.shared
        // macOS lists an app under Microphone only after it has asked once,
        // so ask first; Settings is only useful after a denial.
        if service.microphoneStatus == .notRequested {
            Task { await service.requestMicrophone() }
        } else {
            service.openMicrophoneSettings()
        }
    }

    private func openAccessibilitySettings() {
        StatusBarManager.shared.closePopover()
        PermissionService.shared.openAccessibilitySettings()
    }

    private func openScreenRecordingSettings() {
        StatusBarManager.shared.closePopover()
        PermissionService.shared.openScreenRecordingSettings()
    }

    private func openAbout() {
        StatusBarManager.shared.closePopover()
        WindowManager.shared.openSettingsWindow(selectedCategory: .about)
    }

    private func openHelp() {
        StatusBarManager.shared.closePopover()
        let isJapanese = Locale.preferredLanguages.first?.hasPrefix("ja") == true
        let urlString = isJapanese
            ? "https://yohasebe.github.io/speechdock/index_ja.html"
            : "https://yohasebe.github.io/speechdock/"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSettings() {
        StatusBarManager.shared.closePopover()
        WindowManager.shared.openSettingsWindow()
    }
}

// MARK: - Menu Bar Action Button Style

/// Custom button style with hover effect for menu bar action buttons
struct MenuBarActionButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(0.25)
        } else if isHovering {
            return Color.accentColor.opacity(0.12)
        } else {
            return Color.clear
        }
    }
}

/// Transcription history submenu for menu bar
struct TranscriptionHistoryMenu: View {
    var appState: AppState
    @State private var entries: [TranscriptionHistoryEntry] = []

    var body: some View {
        Menu {
            if entries.isEmpty {
                Text(NSLocalizedString("No history", comment: "Empty transcription history"))
                    .foregroundColor(.secondary)
            } else {
                ForEach(entries) { entry in
                    Button(action: {
                        loadHistoryEntry(entry)
                    }) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(entry.formattedDate) [\(entry.provider)]")
                                .font(.callout)
                            Text(entry.preview)
                        }
                    }
                }

                Divider()

                Button(action: {
                    TranscriptionHistoryService.shared.clearHistory()
                    entries = []
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text(NSLocalizedString("Clear History", comment: "Clear transcription history button"))
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                Text(NSLocalizedString("Transcription History", comment: "Transcription history menu title"))
                    .font(.callout)
                Spacer()
                if !entries.isEmpty {
                    Text("\(entries.count)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .tint(.accentColor)
        .onAppear {
            entries = TranscriptionHistoryService.shared.allEntries
        }
    }

    private func loadHistoryEntry(_ entry: TranscriptionHistoryEntry) {
        StatusBarManager.shared.closePanel()
        appState.showSTTPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            appState.currentTranscription = entry.text
            appState.transcriptionState = .result(entry.text)
        }
    }
}
