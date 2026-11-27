import AppKit

/// Decides the level of the floating speech panels.
///
/// They float above other apps, but while Settings (or a sheet on it) is the
/// window being used, they drop to the normal level so Settings can come to the
/// front. Using a panel again, or switching to another app, puts them back.
@MainActor
final class WindowLevelCoordinator {
    static let shared = WindowLevelCoordinator()

    static let settingsIdentifier = NSUserInterfaceItemIdentifier("settings")
    private static let speechPanelIdentifier = NSUserInterfaceItemIdentifier("speechPanel")

    private var settingsInUse = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// The level for a floating speech panel right now.
    func nextPanelLevel() -> NSWindow.Level { settingsInUse ? .normal : .floating }

    /// Follows which window is in use. Called once at launch.
    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                WindowLevelCoordinator.shared.keyWindowChanged(to: window)
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WindowLevelCoordinator.shared.setSettingsInUse(false, front: nil) }
        })
    }

    func keyWindowChanged(to window: NSWindow) {
        setSettingsInUse(Self.belongsToSettings(window), front: window)
    }

    /// Settings itself, or a sheet or alert attached to it.
    static func belongsToSettings(_ window: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let candidate = current {
            if candidate.identifier == settingsIdentifier { return true }
            current = candidate.sheetParent ?? candidate.parent
        }
        return false
    }

    private func setSettingsInUse(_ inUse: Bool, front: NSWindow?) {
        guard inUse != settingsInUse else { return }
        settingsInUse = inUse
        let level = nextPanelLevel()
        for panel in NSApp.windows where Self.isFloatingSpeechPanel(panel) && panel.level != level {
            panel.level = level
        }
        // Changing a panel's level can order it in front; keep the window in use on top.
        if inUse { front?.orderFront(nil) }
    }

    /// A speech panel in floating style (borderless); standard-window panels stay normal.
    private static func isFloatingSpeechPanel(_ window: NSWindow) -> Bool {
        window.identifier == speechPanelIdentifier && !window.styleMask.contains(.titled)
    }

    static func configureSavePanel(_ panel: NSSavePanel) {
        panel.contentMinSize = NSSize(width: 500, height: 350)
    }
}
