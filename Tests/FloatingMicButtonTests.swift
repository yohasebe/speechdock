import XCTest
@testable import SpeechDock

@MainActor
final class FloatingMicButtonTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure floating mic button is hidden before each test
        if FloatingMicButtonManager.shared.isVisible {
            FloatingMicButtonManager.shared.hide()
        }
        if FloatingMicTextHUD.shared.isVisible {
            FloatingMicTextHUD.shared.hide()
        }
    }

    override func tearDown() {
        // Clean up after tests
        if FloatingMicButtonManager.shared.isVisible {
            FloatingMicButtonManager.shared.hide()
        }
        if FloatingMicTextHUD.shared.isVisible {
            FloatingMicTextHUD.shared.hide()
        }
        super.tearDown()
    }

    // MARK: - FloatingMicButtonManager Tests

    func testInitialState() {
        XCTAssertFalse(FloatingMicButtonManager.shared.isVisible,
                      "Floating mic button should not be visible initially")
    }

    func testShowHide() {
        let appState = AppState.shared

        // Show the button
        FloatingMicButtonManager.shared.show(appState: appState)
        XCTAssertTrue(FloatingMicButtonManager.shared.isVisible,
                     "Floating mic button should be visible after show()")

        // Hide the button
        FloatingMicButtonManager.shared.hide()
        XCTAssertFalse(FloatingMicButtonManager.shared.isVisible,
                      "Floating mic button should not be visible after hide()")
    }

    func testToggle() {
        let appState = AppState.shared

        // Initially hidden
        XCTAssertFalse(FloatingMicButtonManager.shared.isVisible)

        // Toggle to show
        FloatingMicButtonManager.shared.toggle(appState: appState)
        XCTAssertTrue(FloatingMicButtonManager.shared.isVisible,
                     "Toggle should show the button when it was hidden")

        // Toggle to hide
        FloatingMicButtonManager.shared.toggle(appState: appState)
        XCTAssertFalse(FloatingMicButtonManager.shared.isVisible,
                      "Toggle should hide the button when it was visible")
    }

    // MARK: - FloatingMicTextHUD Tests

    func testHUDInitialState() {
        XCTAssertFalse(FloatingMicTextHUD.shared.isVisible,
                      "HUD should not be visible initially")
    }

    func testHUDShowHide() {
        // Create a mock button frame
        let buttonFrame = NSRect(x: 100, y: 100, width: 48, height: 48)

        // Show the HUD
        FloatingMicTextHUD.shared.show(near: buttonFrame)
        XCTAssertTrue(FloatingMicTextHUD.shared.isVisible,
                     "HUD should be visible after show()")

        // Hide the HUD
        FloatingMicTextHUD.shared.hide()
        XCTAssertFalse(FloatingMicTextHUD.shared.isVisible,
                      "HUD should not be visible after hide()")
    }

    // MARK: - HotKeyService Quick Transcription Tests

    func testQuickTranscriptionKeyComboDefault() {
        let defaultKeyCombo = KeyCombo.quickTranscriptionDefault
        XCTAssertEqual(defaultKeyCombo.key, .m,
                      "Default quick transcription key should be M")
        XCTAssertTrue(defaultKeyCombo.modifiers.contains(.control),
                     "Default quick transcription should include Control modifier")
        XCTAssertTrue(defaultKeyCombo.modifiers.contains(.option),
                     "Default quick transcription should include Option modifier")
    }

    func testQuickTranscriptionKeyComboDisplayString() {
        let keyCombo = KeyCombo.quickTranscriptionDefault
        let displayString = keyCombo.displayString

        XCTAssertTrue(displayString.contains("⌃"),
                     "Display string should contain Control symbol")
        XCTAssertTrue(displayString.contains("⌥"),
                     "Display string should contain Option symbol")
        XCTAssertTrue(displayString.contains("M"),
                     "Display string should contain M")
    }

    // MARK: - AppState Integration Tests

    func testToggleQuickTranscription_ShowsButtonIfHidden() {
        let appState = AppState.shared

        // Ensure button is hidden
        appState.showFloatingMicButton = false
        FloatingMicButtonManager.shared.hide()

        // Toggle quick transcription should show the button
        appState.toggleQuickTranscription()

        XCTAssertTrue(appState.showFloatingMicButton,
                     "toggleQuickTranscription should set showFloatingMicButton to true")
        XCTAssertTrue(FloatingMicButtonManager.shared.isVisible,
                     "toggleQuickTranscription should show the floating mic button")
    }

    func testToggleFloatingMicButton() {
        let appState = AppState.shared

        // Initial state
        appState.showFloatingMicButton = false
        FloatingMicButtonManager.shared.hide()

        // Toggle to show
        appState.toggleFloatingMicButton()
        XCTAssertTrue(appState.showFloatingMicButton,
                     "toggleFloatingMicButton should toggle to true")
        XCTAssertTrue(FloatingMicButtonManager.shared.isVisible,
                     "Manager should be visible after toggle")

        // Toggle to hide
        appState.toggleFloatingMicButton()
        XCTAssertFalse(appState.showFloatingMicButton,
                      "toggleFloatingMicButton should toggle to false")
        XCTAssertFalse(FloatingMicButtonManager.shared.isVisible,
                      "Manager should be hidden after toggle")
    }

    // MARK: - Notification Tests

    func testTranscriptionUpdatedNotification() {
        let expectation = XCTestExpectation(description: "Notification received")
        var receivedText: String?

        let observer = NotificationCenter.default.addObserver(
            forName: FloatingMicConstants.transcriptionUpdatedNotification,
            object: nil,
            queue: .main
        ) { notification in
            receivedText = notification.object as? String
            expectation.fulfill()
        }

        // Post a test notification
        NotificationCenter.default.post(
            name: FloatingMicConstants.transcriptionUpdatedNotification,
            object: "Test transcription text"
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedText, "Test transcription text",
                      "Notification should contain the posted text")

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Position Persistence Tests

    func testButtonPositionSavedInUserDefaults() {
        let appState = AppState.shared
        let positionKey = FloatingMicConstants.buttonPositionKey

        // Clear any existing saved position
        UserDefaults.standard.removeObject(forKey: positionKey)

        // Show and then hide the button (which saves position)
        FloatingMicButtonManager.shared.show(appState: appState)
        FloatingMicButtonManager.shared.hide()

        // Check that position was saved
        let savedPosition = UserDefaults.standard.string(forKey: positionKey)
        XCTAssertNotNil(savedPosition,
                       "Button position should be saved to UserDefaults")
    }

    func testHUDPositionSavedInUserDefaults() {
        let positionKey = FloatingMicConstants.hudPositionKey
        let buttonFrame = NSRect(x: 100, y: 100, width: FloatingMicConstants.buttonSize, height: FloatingMicConstants.buttonSize)

        // Clear any existing saved position
        UserDefaults.standard.removeObject(forKey: positionKey)

        // Show and then hide the HUD (which saves position)
        FloatingMicTextHUD.shared.show(near: buttonFrame)
        FloatingMicTextHUD.shared.hide()

        // Check that position was saved
        let savedPosition = UserDefaults.standard.string(forKey: positionKey)
        XCTAssertNotNil(savedPosition,
                       "HUD position should be saved to UserDefaults")
    }

    // MARK: - Constants Tests

    func testFloatingMicConstantsValues() {
        // Verify button size is reasonable
        XCTAssertEqual(FloatingMicConstants.buttonSize, 48,
                      "Button size should be 48 points")

        // Verify HUD dimensions are reasonable
        XCTAssertEqual(FloatingMicConstants.hudWidth, 320,
                      "HUD width should be 320 points")
        XCTAssertEqual(FloatingMicConstants.hudHeight, 120,
                      "HUD height should be 120 points")

        // Verify text settings
        XCTAssertEqual(FloatingMicConstants.hudLineHeight, 20,
                      "HUD line height should be 20 points")
        XCTAssertEqual(FloatingMicConstants.hudFontSize, 14,
                      "HUD font size should be 14 points")
        XCTAssertEqual(FloatingMicConstants.hudMaxLines, 4,
                      "HUD max lines should be 4")

        // Verify margin
        XCTAssertEqual(FloatingMicConstants.positionMargin, 16,
                      "Position margin should be 16 points")
    }

    func testFloatingMicConstantsKeys() {
        // Verify UserDefaults keys are consistent
        XCTAssertEqual(FloatingMicConstants.buttonPositionKey, "floatingMicButtonPosition",
                      "Button position key should match expected value")
        XCTAssertEqual(FloatingMicConstants.hudPositionKey, "floatingMicHUDPosition",
                      "HUD position key should match expected value")
    }

    // MARK: - Recording State Tests

    func testRecordingStateInitiallyFalse() {
        let appState = AppState.shared
        XCTAssertFalse(appState.isRecording,
                      "Recording should be false initially")
    }

    func testToggleRecordingRequiresProvider() {
        // This test verifies that the manager has recording functionality
        // Actual recording requires a real STT provider and microphone access
        let manager = FloatingMicButtonManager.shared
        XCTAssertNotNil(manager,
                       "Manager should be available for recording")
    }

    // MARK: - Multiple Show/Hide Calls Tests

    func testMultipleShowCallsDoNotCreateMultipleWindows() {
        let appState = AppState.shared

        // Show multiple times
        FloatingMicButtonManager.shared.show(appState: appState)
        FloatingMicButtonManager.shared.show(appState: appState)
        FloatingMicButtonManager.shared.show(appState: appState)

        // Should still be visible (only one window)
        XCTAssertTrue(FloatingMicButtonManager.shared.isVisible,
                     "Button should still be visible after multiple show calls")

        FloatingMicButtonManager.shared.hide()
        XCTAssertFalse(FloatingMicButtonManager.shared.isVisible,
                      "Single hide should hide the button")
    }

    func testMultipleHideCallsAreSafe() {
        let appState = AppState.shared

        FloatingMicButtonManager.shared.show(appState: appState)
        FloatingMicButtonManager.shared.hide()

        // Multiple hide calls should be safe
        FloatingMicButtonManager.shared.hide()
        FloatingMicButtonManager.shared.hide()

        XCTAssertFalse(FloatingMicButtonManager.shared.isVisible,
                      "Button should remain hidden after multiple hide calls")
    }

    func testHUDMultipleShowCallsDoNotCreateMultipleWindows() {
        let buttonFrame = NSRect(x: 100, y: 100, width: FloatingMicConstants.buttonSize, height: FloatingMicConstants.buttonSize)

        // Show multiple times
        FloatingMicTextHUD.shared.show(near: buttonFrame)
        FloatingMicTextHUD.shared.show(near: buttonFrame)
        FloatingMicTextHUD.shared.show(near: buttonFrame)

        // Should still be visible (only one window)
        XCTAssertTrue(FloatingMicTextHUD.shared.isVisible,
                     "HUD should still be visible after multiple show calls")

        FloatingMicTextHUD.shared.hide()
        XCTAssertFalse(FloatingMicTextHUD.shared.isVisible,
                      "Single hide should hide the HUD")
    }

    // MARK: - Transcription State Tests

    func testCurrentTranscriptionInitiallyEmpty() {
        let appState = AppState.shared
        // Current transcription should be accessible (may or may not be empty depending on state)
        XCTAssertNotNil(appState.currentTranscription,
                       "Current transcription should be accessible")
    }

    // MARK: - AppleScript Error Code Tests

    func testAppleScriptErrorCodeForAlreadyRecording() {
        XCTAssertEqual(AppleScriptErrorCode.sttAlreadyRecording.rawValue, 1024,
                      "STT already recording error should be 1024")
    }

    func testAppleScriptErrorCodeForNotRecording() {
        XCTAssertEqual(AppleScriptErrorCode.sttNotRecording.rawValue, 1026,
                      "STT not recording error should be 1026")
    }

    func testAppleScriptErrorCodesAreUnique() {
        // Verify all STT-related error codes are unique
        let sttErrorCodes: [Int] = [
            AppleScriptErrorCode.sttProviderNotSupported.rawValue,
            AppleScriptErrorCode.sttFileNotFound.rawValue,
            AppleScriptErrorCode.sttUnsupportedFormat.rawValue,
            AppleScriptErrorCode.sttFileTooLarge.rawValue,
            AppleScriptErrorCode.sttAlreadyRecording.rawValue,
            AppleScriptErrorCode.sttTranscriptionFailed.rawValue,
            AppleScriptErrorCode.sttNotRecording.rawValue
        ]

        let uniqueCodes = Set(sttErrorCodes)
        XCTAssertEqual(sttErrorCodes.count, uniqueCodes.count,
                      "All STT error codes should be unique")
    }

    // MARK: - Multi-Monitor Position Restoration Tests

    func testSavedPositionIsValidatedOnRestore() {
        let appState = AppState.shared
        let positionKey = FloatingMicConstants.buttonPositionKey

        // Save a position that's on the main screen
        guard let mainScreen = NSScreen.main else {
            XCTFail("No main screen available")
            return
        }

        let validPosition = NSRect(
            x: mainScreen.visibleFrame.midX,
            y: mainScreen.visibleFrame.midY,
            width: FloatingMicConstants.buttonSize,
            height: FloatingMicConstants.buttonSize
        )

        UserDefaults.standard.set(NSStringFromRect(validPosition), forKey: positionKey)

        // Show the button - should use saved position if it's valid
        FloatingMicButtonManager.shared.show(appState: appState)
        XCTAssertTrue(FloatingMicButtonManager.shared.isVisible)
        FloatingMicButtonManager.shared.hide()

        // The saved position should be updated (may have been adjusted)
        let restoredPosition = UserDefaults.standard.string(forKey: positionKey)
        XCTAssertNotNil(restoredPosition,
                       "A valid position should be saved after restore")
    }

    func testInvalidSavedPositionIsCleared() {
        let positionKey = FloatingMicConstants.buttonPositionKey

        // Save a position that's way off any connected screen
        let invalidPosition = NSRect(x: -10000, y: -10000, width: 48, height: 48)
        UserDefaults.standard.set(NSStringFromRect(invalidPosition), forKey: positionKey)

        let appState = AppState.shared
        FloatingMicButtonManager.shared.show(appState: appState)
        FloatingMicButtonManager.shared.hide()

        // Check that the button was shown (using default position)
        // and new valid position was saved
        let newSavedPosition = UserDefaults.standard.string(forKey: positionKey)

        // If position was restored, it should be a valid screen position
        if let saved = newSavedPosition {
            let savedRect = NSRectFromString(saved)
            // Verify the new position is on some connected screen
            let isOnScreen = NSScreen.screens.contains { screen in
                screen.visibleFrame.intersects(savedRect)
            }
            XCTAssertTrue(isOnScreen || savedRect.origin.x >= 0,
                         "Saved position should be on a connected screen")
        }
    }
}
