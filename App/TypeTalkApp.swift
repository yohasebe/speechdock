import SwiftUI

@main
struct TypeTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(AppState.shared)
        } label: {
            Image(systemName: AppState.shared.isRecording ? "mic.fill" : "mic")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindow()
                .environment(AppState.shared)
        }
    }
}
