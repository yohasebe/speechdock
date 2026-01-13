import SwiftUI

@main
struct TypeTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState.shared

    init() {
        // Setup status bar manager with custom icon handling
        Task { @MainActor in
            StatusBarManager.shared.setup(appState: AppState.shared)
        }
    }

    var body: some Scene {
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
