import SwiftUI

@main
struct TypeTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarIconView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindow()
                .environment(appState)
        }

        Window("About TypeTalk", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Menu bar icon view that observes AppState for color changes
struct MenuBarIconView: View {
    @Bindable var appState: AppState

    private var iconName: String {
        if appState.isRecording || appState.transcriptionState == .processing {
            return "waveform.badge.mic"  // STT active
        } else if appState.ttsState == .speaking || appState.ttsState == .loading {
            return "speaker.wave.2.fill"  // TTS active
        } else {
            return "waveform"  // Default
        }
    }

    private var iconColor: Color {
        // STT states (red tones)
        if appState.isRecording {
            return .red  // STT recording active
        } else if appState.transcriptionState == .processing {
            return Color.red.opacity(0.7)  // STT processing
        }
        // TTS states (blue tones)
        else if appState.ttsState == .speaking {
            return .blue  // TTS speaking active
        } else if appState.ttsState == .loading {
            return Color.blue.opacity(0.7)  // TTS loading/generating
        }
        // Default
        else {
            return .primary  // Default (adapts to light/dark mode)
        }
    }

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(iconColor)
    }
}
