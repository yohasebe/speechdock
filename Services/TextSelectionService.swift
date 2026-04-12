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

    /// Bundle IDs of apps that expose selected text via AX API as
    /// single-newline-separated plain text, losing paragraph structure.
    /// For these, we skip AX and use the clipboard (HTML/RTF) path to preserve
    /// blank lines between paragraphs.
    /// Includes web browsers and rich-text editors.
    private let clipboardFirstBundleIDs: Set<String> = [
        // Web browsers
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaNext",
        "com.operasoftware.OperaDeveloper",
        "com.operasoftware.OperaGX",
        "org.chromium.Chromium",
        "app.zen-browser.zen",
        "net.kagi.kagimacOS",  // Orion
        // Rich-text editors and mail/document apps
        "com.apple.TextEdit",
        "com.apple.mail",
        "com.apple.Notes",
        "com.apple.Pages",
        "com.apple.iWork.Pages",
        "com.microsoft.Word",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",  // Spark
        "com.airmailapp.airmail2",
        "com.apple.iBooksX",
    ]

    private init() {}

    /// Gets the currently selected text from the frontmost application
    /// Tries accessibility API first, then falls back to clipboard-based approach
    /// - Parameter targetApp: Optional pre-captured app reference (for hotkey scenarios where frontmost app may change)
    func getSelectedText(from targetApp: NSRunningApplication? = nil) async -> String? {
        // Use pre-captured app if provided, otherwise get current frontmost
        let frontApp = targetApp ?? NSWorkspace.shared.frontmostApplication
        dprint("TextSelectionService: getSelectedText called, target app: \(frontApp?.localizedName ?? "unknown") (bundle: \(frontApp?.bundleIdentifier ?? "unknown")), pre-captured: \(targetApp != nil)")

        // For browsers and rich-text editors, skip AX API and go straight to clipboard.
        // AX returns single-newline-separated text from these apps, which collapses
        // paragraph breaks. The clipboard HTML/RTF path preserves blank lines between
        // paragraphs via NSAttributedString's parser.
        let useClipboardFirst = frontApp.flatMap { $0.bundleIdentifier }.map { clipboardFirstBundleIDs.contains($0) } ?? false
        if useClipboardFirst {
            dprint("TextSelectionService: Target is a rich-text app, skipping AX and using clipboard directly")
            let clipboardText = await getSelectedTextViaClipboard(targetApp: frontApp)
            if let text = clipboardText {
                dprint("TextSelectionService: Got text via Clipboard (rich-text path), length: \(text.count)")
                return text
            }
            // If clipboard path failed, fall through to AX as last resort
        }

        // Try accessibility API first (more reliable, less intrusive) for other apps
        if let text = getSelectedTextViaAccessibility(from: frontApp) {
            dprint("TextSelectionService: Got text via Accessibility API, length: \(text.count)")

            return text
        }

        // Clipboard-first path already tried clipboard above; skip redundant retry
        if useClipboardFirst {
            dprint("TextSelectionService: No text found via any method (rich-text path)")
            return nil
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

                // Pick the format that best preserves paragraph structure.
                // See readBestTextFromPasteboard for the selection rationale.
                selectedText = readBestTextFromPasteboard(pasteboard)
                dprint("TextSelectionService: Selected best text representation from clipboard, length: \(selectedText?.count ?? 0)")
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

    /// Read the best available text representation from the pasteboard.
    /// Picks whichever format best preserves paragraph breaks (blank lines):
    /// - If plain text already contains blank lines, use it directly
    ///   (TextEdit, Pages, Notes, and many native apps put structure-preserving plain text)
    /// - Otherwise try HTML with <br><br> injection (web browsers)
    /// - Otherwise try RTF via attributed string walk
    /// - Otherwise return plain text as last resort
    /// Returns nil if the pasteboard has no readable text.
    func readBestTextFromPasteboard(_ pasteboard: NSPasteboard = .general) -> String? {
        let plainText = pasteboard.string(forType: .string)

        // 1. If plain text already preserves paragraph structure (has blank lines),
        // use it directly — it's the most faithful representation.
        if let text = plainText, text.contains("\n\n") {
            return text
        }

        // 2. HTML (web browsers put structured HTML but often collapse plain text)
        if let htmlString = pasteboard.string(forType: htmlType),
           let converted = convertHTMLToFormattedText(htmlString),
           !converted.isEmpty {
            // Only use HTML result if it's at least as structured as plain text
            if converted.contains("\n\n") || plainText == nil || plainText?.isEmpty == true {
                return converted
            }
        }

        // 3. RTF (Word, Pages, Mail rich text)
        if let rtfData = pasteboard.data(forType: .rtf),
           let converted = convertRTFToFormattedText(rtfData),
           !converted.isEmpty {
            if converted.contains("\n\n") || plainText == nil || plainText?.isEmpty == true {
                return converted
            }
        }

        // 4. Fall back to plain text (even without blank lines)
        return plainText
    }

    /// Convert HTML string to formatted plain text preserving layout structure
    private func convertHTMLToFormattedText(_ html: String) -> String? {
        // NSAttributedString's HTML parser represents paragraph breaks as a single \n
        // in the output .string (the visual blank line is stored as paragraphSpacing
        // attribute, which we lose when converting to plain text). To preserve blank
        // lines between paragraphs, inject explicit <br><br> after each block-level
        // closing tag before parsing — these survive parsing as literal \n\n.
        let preprocessedHTML = injectParagraphBreaks(html)

        guard let data = preprocessedHTML.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        return cleanupAttributedStringText(attributedString)
    }

    /// Inject <br><br> after block-level closing tags to preserve paragraph boundaries
    /// through NSAttributedString's HTML parser, which otherwise collapses them to single \n.
    ///
    /// Note: List items (`<li>`, `<dt>`, `<dd>`) and table rows (`<tr>`) are NOT included
    /// — they should be separated by a single newline, not a blank line. Their enclosing
    /// containers (`<ul>`, `<ol>`, `<table>`) still get blank-line treatment.
    private func injectParagraphBreaks(_ html: String) -> String {
        let pattern = #"</(p|div|h[1-6]|blockquote|pre|article|section|header|footer|nav|aside|figure|figcaption|ul|ol|table)\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(
            in: html,
            options: [],
            range: range,
            withTemplate: "</$1><br><br>"
        )
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

        // RTF: walk the attributed string and use paragraph style to detect paragraph breaks.
        return attributedStringToTextPreservingParagraphs(attributedString)
    }

    /// Walk an NSAttributedString and emit plain text with \n\n at paragraph boundaries
    /// (detected via paragraphSpacing / paragraphSpacingBefore in the paragraph style).
    /// Used for RTF where we can't preprocess the source.
    private func attributedStringToTextPreservingParagraphs(_ attrStr: NSAttributedString) -> String? {
        let nsStr = attrStr.string as NSString
        guard nsStr.length > 0 else { return nil }

        var output = ""
        var paragraphStart = 0

        while paragraphStart < nsStr.length {
            let paragraphRange = nsStr.paragraphRange(for: NSRange(location: paragraphStart, length: 0))
            let paragraphText = nsStr.substring(with: paragraphRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !paragraphText.isEmpty {
                if !output.isEmpty {
                    // Check paragraph style to decide: blank line or single newline
                    let style = attrStr.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
                    let hasSpacing = (style?.paragraphSpacing ?? 0) > 0 || (style?.paragraphSpacingBefore ?? 0) > 0
                    output += hasSpacing ? "\n\n" : "\n"
                }
                output += paragraphText
            }

            paragraphStart = NSMaxRange(paragraphRange)
        }

        // Apply the same whitespace normalization as cleanupAttributedStringText
        var result = output.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Clean up attributed string text while preserving layout structure
    private func cleanupAttributedStringText(_ attributedString: NSAttributedString) -> String? {
        // Get the plain text from attributed string (preserves line breaks from structure)
        var result = attributedString.string

        // Replace multiple spaces/tabs with single space (applies within lines)
        result = result.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        // Trim leading/trailing whitespace from each line.
        // This converts whitespace-only lines (e.g. from <p>&nbsp;</p>) to empty lines.
        result = result.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // Collapse 3+ consecutive newlines to exactly 2 (one blank line between paragraphs).
        // Must run AFTER line trimming so that "whitespace-only lines" become true empties
        // and participate in the collapse.
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
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
    private func getSelectedTextViaAccessibility(from targetApp: NSRunningApplication? = nil) -> String? {
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
