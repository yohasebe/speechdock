import AppKit
import Carbon

final class ClipboardService {
    static let shared = ClipboardService()

    private init() {}

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copyAndPaste(_ text: String) {
        copyToClipboard(text)

        // Use AppleScript to paste - more reliable across different apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.pasteWithAppleScript()
        }
    }

    private func pasteWithAppleScript() {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
                // Fallback to CGEvent
                simulatePasteWithCGEvent()
            }
        }
    }

    private func simulatePasteWithCGEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key code for 'V' is 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
