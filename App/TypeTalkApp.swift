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
    var appState: AppState

    private var iconColor: Color {
        if appState.isRecording {
            return .red  // STT recording
        } else if appState.ttsState == .speaking {
            return .green  // TTS playback
        } else {
            return .primary  // Default (adapts to light/dark mode)
        }
    }

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .foregroundStyle(iconColor)
    }
}
