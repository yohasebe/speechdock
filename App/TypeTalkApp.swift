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

    // No SwiftUI scenes needed - all windows managed by WindowManager
    // This prevents Settings/About from opening automatically on launch
    var body: some Scene {
        // Empty Settings scene that never opens automatically
        // Settings scenes don't open on launch by default, unlike WindowGroup
        Settings {
            EmptyView()
        }
    }
}
