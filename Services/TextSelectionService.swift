import AppKit

/// Service for getting selected text from the frontmost application
final class TextSelectionService {
    static let shared = TextSelectionService()

    /// Lock to prevent concurrent selection operations
    private let selectionLock = NSLock()

    /// Maximum time to wait for copy operation (seconds)
    private let maxCopyWaitTime: TimeInterval = 0.3

    /// Polling interval for clipboard change detection
    private let pollInterval: TimeInterval = 0.02

    private init() {}

    /// Gets the currently selected text from the frontmost application
    /// Tries accessibility API first, then falls back to clipboard-based approach
    func getSelectedText() -> String? {
        // Try accessibility API first (more reliable, less intrusive)
        if let text = getSelectedTextViaAccessibility() {
            return text
        }

        // Fall back to clipboard-based approach with proper synchronization
        return getSelectedTextViaClipboard()
    }

    /// Get selected text using clipboard-based approach with race condition protection
    private func getSelectedTextViaClipboard() -> String? {
        selectionLock.lock()
        defer { selectionLock.unlock() }

        let clipboardService = ClipboardService.shared
        let pasteboard = NSPasteboard.general

        // Save current clipboard state (preserves all content types)
        let savedState = clipboardService.saveClipboardState()
        let initialChangeCount = pasteboard.changeCount

        // Clear clipboard to detect if copy succeeds
        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount

        // Simulate Cmd+C to copy selection
        copySelectionWithAppleScript()

        // Poll for clipboard change with timeout
        var selectedText: String? = nil
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < maxCopyWaitTime {
            if pasteboard.changeCount != clearedChangeCount {
                // Clipboard was updated, get the text
                selectedText = pasteboard.string(forType: .string)
                break
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        // Restore original clipboard contents if not modified by another app
        // We check if the clipboard was modified more than expected
        // (our clear + potential copy = 2 changes max)
        let totalChanges = pasteboard.changeCount - initialChangeCount
        if totalChanges <= 2 {
            clipboardService.restoreClipboardState(savedState)
        } else {
            #if DEBUG
            print("TextSelectionService: Clipboard modified externally, not restoring (changes: \(totalChanges))")
            #endif
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
            #if DEBUG
            if let error = error {
                print("AppleScript error: \(error)")
            }
            #endif
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
