import SwiftUI

@main
struct SpeechDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState.shared

    // Note: StatusBarManager setup is done in AppDelegate.applicationDidFinishLaunching
    // to ensure proper initialization timing

    var body: some Scene {
        // Minimal scene required for menu bar app
        Settings {
            EmptyView()
        }
        .commands {
            // Replace default About command to open our custom AboutWindow
            CommandGroup(replacing: .appInfo) {
                Button("About SpeechDock") {
                    WindowManager.shared.openAboutWindow()
                }
            }

            // Replace default Settings command to open our custom SettingsWindow
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    WindowManager.shared.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Replace default Help command to open GitHub documentation
            CommandGroup(replacing: .help) {
                Button("SpeechDock Help") {
                    if let url = URL(string: "https://github.com/yohasebe/speechdock") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
