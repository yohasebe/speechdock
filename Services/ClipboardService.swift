import AppKit

final class ClipboardService {
    static let shared = ClipboardService()

    /// Lock to prevent concurrent clipboard operations
    private let clipboardLock = NSLock()

    /// Maximum time to wait for clipboard operations (seconds)
    private let maxWaitTime: TimeInterval = 0.5

    private init() {}

    /// Copy text to clipboard with thread safety
    func copyToClipboard(_ text: String) {
        clipboardLock.lock()
        defer { clipboardLock.unlock() }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copy text and paste it to the frontmost application
    /// Uses polling to verify clipboard update before pasting, with retry logic
    @discardableResult
    func copyAndPaste(_ text: String) async -> Bool {
        // Perform clipboard operations synchronously on main thread
        let success = await MainActor.run {
            clipboardLock.lock()
            defer { clipboardLock.unlock() }

            let pasteboard = NSPasteboard.general

            // Retry up to 3 times if clipboard gets modified unexpectedly
            for attempt in 1...3 {
                let previousChangeCount = pasteboard.changeCount

                // Set the text to clipboard
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)

                // Verify clipboard was updated
                guard pasteboard.changeCount != previousChangeCount else {
                    #if DEBUG
                    print("ClipboardService: Failed to update clipboard (attempt \(attempt))")
                    #endif
                    continue
                }

                // Verify text is still what we set (no race condition)
                if pasteboard.string(forType: .string) == text {
                    return true
                } else {
                    #if DEBUG
                    print("ClipboardService: Clipboard content changed unexpectedly (attempt \(attempt))")
                    #endif
                }
            }
            return false
        }

        guard success else {
            #if DEBUG
            print("ClipboardService: Failed to set clipboard after 3 attempts")
            #endif
            return false
        }

        // Short delay to allow clipboard to stabilize before pasting
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Perform paste using CGEvent (more reliable, no System Events permission required)
        await MainActor.run {
            simulatePasteWithCGEvent()
        }
        return true
    }

    /// Simulate Cmd+V using CGEvent (no System Events permission required)
    private func simulatePasteWithCGEvent() {
        // Key code for 'V' is 9
        let keyCodeV: CGKeyCode = 9

        let source = CGEventSource(stateID: .hidSystemState)

        // Create key down event with Command modifier
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true) else {
            #if DEBUG
            print("ClipboardService: Failed to create key down event")
            #endif
            return
        }
        keyDown.flags = .maskCommand

        // Create key up event with Command modifier
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false) else {
            #if DEBUG
            print("ClipboardService: Failed to create key up event")
            #endif
            return
        }
        keyUp.flags = .maskCommand

        // Post events to the HID system
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        #if DEBUG
        print("ClipboardService: Sent Cmd+V via CGEvent")
        #endif
    }

    // MARK: - Clipboard State Preservation

    /// Represents saved clipboard state for restoration
    struct ClipboardState {
        let changeCount: Int
        let items: [NSPasteboardItem]

        init(pasteboard: NSPasteboard) {
            self.changeCount = pasteboard.changeCount
            // Deep copy pasteboard items to preserve their content
            self.items = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
                let newItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        newItem.setData(data, forType: type)
                    }
                }
                return newItem.types.isEmpty ? nil : newItem
            } ?? []
        }
    }

    /// Save current clipboard state
    func saveClipboardState() -> ClipboardState {
        clipboardLock.lock()
        defer { clipboardLock.unlock() }
        return ClipboardState(pasteboard: NSPasteboard.general)
    }

    /// Restore clipboard state if it hasn't been modified by another app
    /// Returns true if restoration was performed, false if clipboard was modified externally
    @discardableResult
    func restoreClipboardState(_ state: ClipboardState) -> Bool {
        clipboardLock.lock()
        defer { clipboardLock.unlock() }

        let pasteboard = NSPasteboard.general

        // Check if clipboard was modified by another app since our operation
        // If changeCount increased by more than 1, another app wrote to clipboard
        let changesSinceOurOperation = pasteboard.changeCount - state.changeCount
        if changesSinceOurOperation > 2 {
            // Another app modified the clipboard, don't overwrite their content
            #if DEBUG
            print("ClipboardService: Skipping restore - clipboard modified by another app (changes: \(changesSinceOurOperation))")
            #endif
            return false
        }

        // Restore the original content
        pasteboard.clearContents()
        if !state.items.isEmpty {
            pasteboard.writeObjects(state.items)
        }

        return true
    }
}
