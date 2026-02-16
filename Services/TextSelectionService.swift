import AppKit

/// Service for getting selected text from the frontmost application
final class TextSelectionService {
    static let shared = TextSelectionService()

    /// Maximum time to wait for copy operation (seconds)
    /// Chrome, LINE, and other apps may need more time due to multi-process architecture
    private let maxCopyWaitTime: TimeInterval = 0.8

    /// Polling interval for clipboard change detection
    private let pollInterval: TimeInterval = 0.02

    /// UTType for HTML content
    private let htmlType = NSPasteboard.PasteboardType.html

    private init() {}

    /// Gets the currently selected text from the frontmost application
    /// Tries accessibility API first, then falls back to clipboard-based approach
    /// - Parameter targetApp: Optional pre-captured app reference (for hotkey scenarios where frontmost app may change)
    func getSelectedText(from targetApp: NSRunningApplication? = nil) async -> String? {
        // Use pre-captured app if provided, otherwise get current frontmost
        let frontApp = targetApp ?? NSWorkspace.shared.frontmostApplication
        dprint("TextSelectionService: getSelectedText called, target app: \(frontApp?.localizedName ?? "unknown") (bundle: \(frontApp?.bundleIdentifier ?? "unknown")), pre-captured: \(targetApp != nil)")


        // Try accessibility API first (more reliable, less intrusive)
        if let text = getSelectedTextViaAccessibility(from: frontApp) {
            dprint("TextSelectionService: Got text via Accessibility API, length: \(text.count)")

            return text
        }

        // Fall back to clipboard-based approach with proper synchronization
        // For clipboard approach, we need to activate the target app to send Cmd+C
        let clipboardText = await getSelectedTextViaClipboard(targetApp: frontApp)
        #if DEBUG
        if let text = clipboardText {
            dprint("TextSelectionService: Got text via Clipboard fallback, length: \(text.count)")
        } else {
            dprint("TextSelectionService: No text found via any method")
        }
        #endif
        return clipboardText
    }

    /// Get selected text using clipboard-based approach with race condition protection
    /// Uses async/await to avoid blocking the main thread during polling
    /// - Parameter targetApp: The app to copy from (if provided, will be activated before sending Cmd+C)
    @MainActor
    private func getSelectedTextViaClipboard(targetApp: NSRunningApplication?) async -> String? {
        // Use actor isolation instead of lock for async context
        let clipboardService = ClipboardService.shared
        let pasteboard = NSPasteboard.general

        // Save current clipboard state (preserves all content types)
        let savedState = clipboardService.saveClipboardState()
        let initialChangeCount = pasteboard.changeCount

        // Clear clipboard to detect if copy succeeds
        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount

        // If we have a target app, ALWAYS activate it to ensure it receives the key event
        // This is critical when SpeechDock's panel is open, as the hotkey handling might have
        // caused SpeechDock to become active
        if let targetApp = targetApp {
            #if DEBUG
            let currentFrontmost = NSWorkspace.shared.frontmostApplication
            dprint("TextSelectionService: Current frontmost: \(currentFrontmost?.localizedName ?? "none"), target: \(targetApp.localizedName ?? "unknown")")
            #endif

            // Force activate the target app, ignoring other apps
            targetApp.activate(options: .activateIgnoringOtherApps)

            // Wait for activation to complete - apps like Chrome need more time
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms

            #if DEBUG
            let newFrontmost = NSWorkspace.shared.frontmostApplication
            dprint("TextSelectionService: After activation, frontmost: \(newFrontmost?.localizedName ?? "none")")
            #endif
        }

        // Small delay before sending copy command to ensure target app is ready
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Simulate Cmd+C to copy selection using CGEvent (no System Events permission required)
        copySelectionWithCGEvent()

        // Poll for clipboard change with timeout using async sleep
        var selectedText: String? = nil
        let startTime = Date()
        let pollIntervalNanoseconds = UInt64(pollInterval * 1_000_000_000)
        dprint("TextSelectionService: Clipboard fallback - waiting for copy response (timeout: \(maxCopyWaitTime)s)")


        while Date().timeIntervalSince(startTime) < maxCopyWaitTime {
            if pasteboard.changeCount != clearedChangeCount {
                // Clipboard was updated
                #if DEBUG
                let availableTypes = pasteboard.types?.map { $0.rawValue } ?? []
                dprint("TextSelectionService: Clipboard updated, available types: \(availableTypes)")
                #endif

                // Try to get rich text formats for better layout preservation

                // 1. Try HTML first (web browsers)
                if let htmlString = pasteboard.string(forType: htmlType) {
                    selectedText = convertHTMLToFormattedText(htmlString)
                    dprint("TextSelectionService: Got HTML from clipboard, converted to formatted text")

                }

                // 2. Try RTF if HTML not available (Word, Pages, etc.)
                if (selectedText == nil || selectedText?.isEmpty == true),
                   let rtfData = pasteboard.data(forType: .rtf) {
                    selectedText = convertRTFToFormattedText(rtfData)
                    dprint("TextSelectionService: Got RTF from clipboard, converted to formatted text")

                }

                // 3. Fall back to plain text if rich text conversion failed or unavailable
                if selectedText == nil || selectedText?.isEmpty == true {
                    selectedText = pasteboard.string(forType: .string)
                    #if DEBUG
                    if selectedText != nil {
                        dprint("TextSelectionService: Got plain text from clipboard")
                    }
                    #endif
                }
                break
            }
            // Use Task.sleep instead of Thread.sleep to avoid blocking
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        #if DEBUG
        let elapsed = Date().timeIntervalSince(startTime)
        if selectedText != nil {
            dprint("TextSelectionService: Clipboard fallback succeeded in \(String(format: "%.3f", elapsed))s")
        } else {
            dprint("TextSelectionService: Clipboard fallback timed out after \(String(format: "%.3f", elapsed))s")
        }
        #endif

        // Restore original clipboard contents if not modified by another app
        // We check if the clipboard was modified more than expected
        // (our clear + potential copy = 2 changes max)
        let totalChanges = pasteboard.changeCount - initialChangeCount
        if totalChanges <= 2 {
            clipboardService.restoreClipboardState(savedState)
        } else {
            dprint("TextSelectionService: Clipboard modified externally, not restoring (changes: \(totalChanges))")

        }

        return selectedText
    }

    /// Convert HTML string to formatted plain text preserving layout structure
    private func convertHTMLToFormattedText(_ html: String) -> String? {
        guard let data = html.data(using: .utf8) else { return nil }

        // Use NSAttributedString to parse HTML
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        return cleanupAttributedStringText(attributedString)
    }

    /// Convert RTF data to formatted plain text preserving layout structure
    private func convertRTFToFormattedText(_ rtfData: Data) -> String? {
        // Use NSAttributedString to parse RTF
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]

        guard let attributedString = try? NSAttributedString(data: rtfData, options: options, documentAttributes: nil) else {
            return nil
        }

        return cleanupAttributedStringText(attributedString)
    }

    /// Clean up attributed string text while preserving layout structure
    private func cleanupAttributedStringText(_ attributedString: NSAttributedString) -> String? {
        // Get the plain text from attributed string (preserves line breaks from structure)
        var result = attributedString.string

        // Clean up excessive whitespace while preserving intentional line breaks
        // Replace multiple spaces with single space
        result = result.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        // Replace more than 2 consecutive newlines with just 2
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        // Trim leading/trailing whitespace from each line
        result = result.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // Trim overall leading/trailing whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result.isEmpty ? nil : result
    }

    /// Simulate Cmd+C using CGEvent (no System Events permission required)
    private func copySelectionWithCGEvent() {
        // Key code for 'C' is 8
        let keyCodeC: CGKeyCode = 8

        let source = CGEventSource(stateID: .hidSystemState)

        // Create key down event with Command modifier
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true) else {
            dprint("TextSelectionService: Failed to create key down event")

            return
        }
        keyDown.flags = .maskCommand

        // Create key up event with Command modifier
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false) else {
            dprint("TextSelectionService: Failed to create key up event")

            return
        }
        keyUp.flags = .maskCommand

        // Post events to the HID system
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        dprint("TextSelectionService: Sent Cmd+C via CGEvent")

    }

    /// Alternative method using Accessibility API (requires accessibility permissions)
    /// - Parameter targetApp: The app to get selected text from (if nil, uses current frontmost)
    func getSelectedTextViaAccessibility(from targetApp: NSRunningApplication? = nil) -> String? {
        guard let app = targetApp ?? NSWorkspace.shared.frontmostApplication else {
            dprint("TextSelectionService: No target application")

            return nil
        }
        dprint("TextSelectionService: Trying Accessibility API for \(app.localizedName ?? "unknown") (bundle: \(app.bundleIdentifier ?? "unknown"))")


        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard focusResult == .success,
              let element = focusedElement,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            dprint("TextSelectionService: Accessibility API failed to get focused element (result: \(focusResult.rawValue))")

            return nil
        }

        // Safe cast after type verification
        let axElement = element as! AXUIElement
        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedText)

        guard textResult == .success, let text = selectedText as? String else {
            dprint("TextSelectionService: Accessibility API failed to get selected text (result: \(textResult.rawValue))")

            return nil
        }

        return text.isEmpty ? nil : text
    }
}
