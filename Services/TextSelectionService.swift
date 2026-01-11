import AppKit

/// Service for getting selected text from the frontmost application
final class TextSelectionService {
    static let shared = TextSelectionService()

    private init() {}

    /// Gets the currently selected text from the frontmost application
    /// Tries accessibility API first, then falls back to clipboard-based approach
    func getSelectedText() -> String? {
        print("TextSelectionService: Attempting to get selected text...")

        // Try accessibility API first (more reliable, less intrusive)
        if let text = getSelectedTextViaAccessibility() {
            print("TextSelectionService: Got text via accessibility: \(text.prefix(50))...")
            return text
        }

        print("TextSelectionService: Accessibility failed, trying clipboard method...")

        // Fall back to clipboard-based approach
        let pasteboard = NSPasteboard.general
        let savedContents = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        // Clear clipboard
        pasteboard.clearContents()

        // Simulate Cmd+C to copy selection
        copySelectionWithAppleScript()

        // Longer delay to allow copy to complete
        Thread.sleep(forTimeInterval: 0.15)

        // Check if clipboard was updated
        let newChangeCount = pasteboard.changeCount
        var selectedText: String? = nil

        if newChangeCount != savedChangeCount {
            selectedText = pasteboard.string(forType: .string)
            print("TextSelectionService: Got text via clipboard: \(selectedText?.prefix(50) ?? "nil")...")
        } else {
            print("TextSelectionService: Clipboard was not updated")
        }

        // Restore original clipboard contents
        pasteboard.clearContents()
        if let savedContents = savedContents {
            pasteboard.setString(savedContents, forType: .string)
        }

        return selectedText
    }

    private func copySelectionWithAppleScript() {
        let script = """
        tell application "System Events"
            keystroke "c" using command down
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        }
    }

    /// Alternative method using Accessibility API (requires accessibility permissions)
    func getSelectedTextViaAccessibility() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard focusResult == .success, let element = focusedElement else {
            return nil
        }

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)

        guard textResult == .success, let text = selectedText as? String else {
            return nil
        }

        return text.isEmpty ? nil : text
    }
}
