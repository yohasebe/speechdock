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

    private var iconState: Int {
        // Return a unique value for each state to force view update
        if appState.isRecording { return 1 }
        if appState.transcriptionState == .processing { return 2 }
        if appState.ttsState == .speaking { return 3 }
        if appState.ttsState == .loading { return 4 }
        return 0
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
        Image("MenuBarIcon")
            .renderingMode(.template)
            .foregroundStyle(iconColor)
            .id(iconState)  // Force view recreation when state changes
    }
}
