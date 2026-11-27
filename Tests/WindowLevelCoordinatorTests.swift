import AppKit
import XCTest
@testable import SpeechDock

@MainActor
final class WindowLevelCoordinatorTests: XCTestCase {
    func testRepeatedPanelPresentationDoesNotEscalateLevel() {
        for _ in 0..<110 { XCTAssertEqual(WindowLevelCoordinator.shared.speechPanelLevel(), .floating) }
    }

    func testSavePanelKeepsSystemLevelAndFitsSmallDisplay() {
        let panel = NSSavePanel()
        let systemLevel = panel.level
        WindowLevelCoordinator.configureSavePanel(panel)
        XCTAssertEqual(panel.level, systemLevel)
        XCTAssertLessThanOrEqual(panel.contentMinSize.width, 600)
        XCTAssertLessThanOrEqual(panel.contentMinSize.height, 400)
    }

    func testAlertAttachesToFloatingParent() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        let alert = NSAlert()
        alert.messageText = "Test"
        WindowPresentation.alert(alert, parent: window)
        XCTAssertEqual(alert.window.sheetParent, window)
        window.endSheet(alert.window)
        window.orderOut(nil)
    }

    private func window(_ identifier: String, titled: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: titled ? [.titled, .closable] : [.borderless],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        return window
    }

    func testSettingsInUseLowersOnlyFloatingSpeechPanels() {
        let coordinator = WindowLevelCoordinator.shared
        let floatingPanel = window("speechPanel", titled: false)
        floatingPanel.level = .floating
        let standardPanel = window("speechPanel", titled: true)
        standardPanel.level = .normal
        let subtitle = window("subtitle", titled: false)
        subtitle.level = .floating
        let settings = window("settings", titled: true)
        defer { [floatingPanel, standardPanel, subtitle, settings].forEach { $0.close() } }

        coordinator.keyWindowChanged(to: settings)
        XCTAssertEqual(floatingPanel.level, .normal)
        XCTAssertEqual(coordinator.speechPanelLevel(), .normal)
        XCTAssertEqual(standardPanel.level, .normal)
        XCTAssertEqual(subtitle.level, .floating)

        coordinator.keyWindowChanged(to: floatingPanel)
        XCTAssertEqual(floatingPanel.level, .floating)
        XCTAssertEqual(coordinator.speechPanelLevel(), .floating)
    }

    func testWindowsAttachedToSettingsCountAsSettings() {
        let settings = window("settings", titled: true)
        let child = window("", titled: false)
        let other = window("speechPanel", titled: false)
        defer { [settings, child, other].forEach { $0.close() } }
        settings.addChildWindow(child, ordered: .above)

        XCTAssertTrue(WindowLevelCoordinator.belongsToSettings(settings))
        XCTAssertTrue(WindowLevelCoordinator.belongsToSettings(child))
        XCTAssertFalse(WindowLevelCoordinator.belongsToSettings(other))
    }
}
