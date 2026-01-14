import AppKit

/// Coordinates window levels to ensure the most recently shown panel appears on top
/// - STT/TTS panels and menu bar popover use dynamic levels
/// - Save dialogs always use the highest level
/// - Level resets when panels are closed to prevent unbounded growth
@MainActor
final class WindowLevelCoordinator {
    static let shared = WindowLevelCoordinator()

    /// Maximum number of level increments before wrapping (safety limit)
    /// In practice, reset() is called when panels close, so this rarely triggers
    private static let maxLevelOffset = 100

    /// Base level for panels (above popUpMenu)
    private let baseLevel = Int(NSWindow.Level.popUpMenu.rawValue) + 1

    /// Current panel level (incremented each time a panel is shown)
    private var currentLevel: Int

    /// Level for save dialogs (always highest)
    static let saveDialogLevel = NSWindow.Level(rawValue: Int(NSWindow.Level.popUpMenu.rawValue) + 500)

    private init() {
        currentLevel = baseLevel
    }

    /// Get the next panel level (for showing a new panel on top)
    func nextPanelLevel() -> NSWindow.Level {
        currentLevel += 1
        // Wrap around if exceeds max offset (safety net, rarely reached due to reset())
        if currentLevel > baseLevel + Self.maxLevelOffset {
            currentLevel = baseLevel + 1
        }
        return NSWindow.Level(rawValue: currentLevel)
    }

    /// Reset to base level (called when panels are closed)
    /// This prevents unbounded level growth during normal use
    func reset() {
        currentLevel = baseLevel
    }

    /// Configure a save panel to appear above floating panels
    /// Use this to ensure save dialogs are always visible
    static func configureSavePanel(_ savePanel: NSSavePanel) {
        savePanel.level = saveDialogLevel
        savePanel.contentMinSize = NSSize(width: 400, height: 250)
        savePanel.setContentSize(NSSize(width: 500, height: 350))
    }
}
