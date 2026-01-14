import XCTest
@testable import TypeTalk

@MainActor
final class WindowLevelCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset coordinator before each test
        WindowLevelCoordinator.shared.reset()
    }

    func testNextPanelLevelIncrementsLevel() {
        let firstLevel = WindowLevelCoordinator.shared.nextPanelLevel()
        let secondLevel = WindowLevelCoordinator.shared.nextPanelLevel()

        XCTAssertGreaterThan(secondLevel.rawValue, firstLevel.rawValue,
                            "Each call to nextPanelLevel should increment the level")
    }

    func testResetResetsLevel() {
        // Get a few levels to increment
        _ = WindowLevelCoordinator.shared.nextPanelLevel()
        _ = WindowLevelCoordinator.shared.nextPanelLevel()
        _ = WindowLevelCoordinator.shared.nextPanelLevel()

        // Reset
        WindowLevelCoordinator.shared.reset()

        // Get new level after reset
        let levelAfterReset = WindowLevelCoordinator.shared.nextPanelLevel()

        // Get another level to compare
        _ = WindowLevelCoordinator.shared.nextPanelLevel()
        WindowLevelCoordinator.shared.reset()
        let secondResetLevel = WindowLevelCoordinator.shared.nextPanelLevel()

        XCTAssertEqual(levelAfterReset.rawValue, secondResetLevel.rawValue,
                      "Level after reset should be consistent")
    }

    func testSaveDialogLevelIsHigherThanPanelLevel() {
        let panelLevel = WindowLevelCoordinator.shared.nextPanelLevel()
        let saveDialogLevel = WindowLevelCoordinator.saveDialogLevel

        XCTAssertGreaterThan(saveDialogLevel.rawValue, panelLevel.rawValue,
                            "Save dialog level should always be higher than panel level")
    }

    func testLevelWrapsAfterMaxOffset() {
        // Get many levels to trigger wrap around
        var previousLevel: Int = 0
        var wrapOccurred = false

        for i in 0..<110 {
            let level = WindowLevelCoordinator.shared.nextPanelLevel()
            if i > 0 && level.rawValue < previousLevel {
                wrapOccurred = true
                break
            }
            previousLevel = level.rawValue
        }

        XCTAssertTrue(wrapOccurred, "Level should wrap after exceeding max offset")
    }

    func testConfigureSavePanelSetsCorrectLevel() {
        let savePanel = NSSavePanel()
        WindowLevelCoordinator.configureSavePanel(savePanel)

        XCTAssertEqual(savePanel.level, WindowLevelCoordinator.saveDialogLevel,
                      "Save panel level should be set to saveDialogLevel")
    }

    func testConfigureSavePanelSetsMinSize() {
        let savePanel = NSSavePanel()
        WindowLevelCoordinator.configureSavePanel(savePanel)

        XCTAssertEqual(savePanel.contentMinSize.width, 400,
                      "Save panel min width should be 400")
        XCTAssertEqual(savePanel.contentMinSize.height, 250,
                      "Save panel min height should be 250")
    }
}
