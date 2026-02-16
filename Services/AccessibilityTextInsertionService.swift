import ApplicationServices
import AppKit

/// Service for inserting text into the frontmost application using Accessibility API
/// Falls back to clipboard paste when direct insertion is not supported
@MainActor
final class AccessibilityTextInsertionService {
    static let shared = AccessibilityTextInsertionService()

    private init() {}

    // MARK: - Capability Detection

    /// Check if the frontmost app's focused element supports direct text insertion
    func canUseDirectInsertion() -> Bool {
        guard let focusedElement = getFocusedTextElement() else {
            return false
        }

        // Check if value attribute is settable
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXValueAttribute as CFString,
            &settable
        )

        return result == .success && settable.boolValue
    }

    /// Get information about the current text insertion capability
    func getInsertionCapability() -> InsertionCapability {
        guard let focusedElement = getFocusedTextElement() else {
            return .notAvailable(reason: "No focused text element")
        }

        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXValueAttribute as CFString,
            &settable
        )

        if result == .success && settable.boolValue {
            return .directInsertion
        } else {
            return .clipboardFallback
        }
    }

    // MARK: - Text Insertion

    /// Insert text at the current cursor position in the frontmost app
    /// Automatically chooses the best method (direct or clipboard)
    func insertText(_ text: String) async {
        if canUseDirectInsertion() {
            let success = insertTextDirectly(text)
            if !success {
                // Fallback to clipboard
                await ClipboardService.shared.copyAndPaste(text)
            }
        } else {
            await ClipboardService.shared.copyAndPaste(text)
        }
    }

    /// Insert text directly using Accessibility API
    /// Returns true if successful
    func insertTextDirectly(_ text: String) -> Bool {
        guard let focusedElement = getFocusedTextElement() else {
            return false
        }

        // Get current value and cursor position
        var currentValue: AnyObject?
        AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &currentValue
        )

        var selectedRange: AnyObject?
        AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )

        // Build new value with inserted text
        let currentText = (currentValue as? String) ?? ""
        let newText: String

        if let rangeValue = selectedRange,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            let axValue = rangeValue as! AXValue  // Safe after CFGetTypeID check
            var cfRange = CFRange()
            if AXValueGetValue(axValue, .cfRange, &cfRange) {
                let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
                if let swiftRange = Range(nsRange, in: currentText) {
                    // Replace selected text or insert at cursor
                    newText = currentText.replacingCharacters(in: swiftRange, with: text)
                } else {
                    // Append if range invalid
                    newText = currentText + text
                }
            } else {
                newText = currentText + text
            }
        } else {
            // No selection info, append to end
            newText = currentText + text
        }

        // Set new value
        let result = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )

        if result == .success {
            // Move cursor to end of inserted text
            let newCursorPosition = newText.count
            setCursorPosition(focusedElement, position: newCursorPosition)
            return true
        }

        return false
    }

    /// Replace partial text with new text (for streaming updates)
    /// - Parameters:
    ///   - oldText: The previously inserted partial text to replace
    ///   - newText: The new text to insert
    func replacePartialText(oldText: String, with newText: String) -> Bool {
        guard let focusedElement = getFocusedTextElement() else {
            return false
        }

        var currentValue: AnyObject?
        AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &currentValue
        )

        guard let currentText = currentValue as? String else {
            return false
        }

        // Find and replace the old text at the end
        if currentText.hasSuffix(oldText) {
            let newValue = String(currentText.dropLast(oldText.count)) + newText
            let result = AXUIElementSetAttributeValue(
                focusedElement,
                kAXValueAttribute as CFString,
                newValue as CFTypeRef
            )
            return result == .success
        }

        return false
    }

    // MARK: - Private Helpers

    private func getFocusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        guard appResult == .success,
              let appRef = focusedApp,
              CFGetTypeID(appRef) == AXUIElementGetTypeID() else {
            dprint("AccessibilityService: Failed to get focused app, result=\(appResult.rawValue)")

            return nil
        }

        let appElement = appRef as! AXUIElement  // Safe after CFGetTypeID check

        // Get app name for debugging
        var appTitle: AnyObject?
        AXUIElementCopyAttributeValue(appElement, kAXTitleAttribute as CFString, &appTitle)
        dprint("AccessibilityService: Focused app = \(appTitle as? String ?? "unknown")")


        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard elementResult == .success,
              let elementRef = focusedElement,
              CFGetTypeID(elementRef) == AXUIElementGetTypeID() else {
            dprint("AccessibilityService: Failed to get focused element, result=\(elementResult.rawValue)")

            return nil
        }

        let element = elementRef as! AXUIElement  // Safe after CFGetTypeID check

        // Check if it's a text input element
        var role: AnyObject?
        AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        )
        dprint("AccessibilityService: Focused element role = \(role as? String ?? "nil")")


        let textRoles: Set<String> = [
            kAXTextFieldRole as String,  // AXTextField
            kAXTextAreaRole as String,   // AXTextArea
            kAXComboBoxRole as String,   // AXComboBox
            "AXSearchField",             // kAXSearchFieldRole
            "AXStaticText",              // Some apps use this
            "AXScrollArea",              // Word uses this for document
            "AXWebArea",                 // Web content
        ]

        guard let roleString = role as? String else {
            dprint("AccessibilityService: No role string")

            return nil
        }

        // More permissive: check if it has a value attribute that's settable
        // instead of strictly checking role
        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        dprint("AccessibilityService: Value settable = \(settable.boolValue), result = \(settableResult.rawValue)")


        // Accept if role is in textRoles OR if value is settable
        if textRoles.contains(roleString) || (settableResult == .success && settable.boolValue) {
            return element
        }
        dprint("AccessibilityService: Role '\(roleString)' not accepted and value not settable")

        return nil
    }

    private func setCursorPosition(_ element: AXUIElement, position: Int) {
        var range = CFRange(location: position, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }
    }

    // MARK: - Types

    enum InsertionCapability {
        case directInsertion
        case clipboardFallback
        case notAvailable(reason: String)

        var supportsStreaming: Bool {
            if case .directInsertion = self {
                return true
            }
            return false
        }
    }
}
