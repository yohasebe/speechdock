import AppKit

// MARK: - Copy to Clipboard Command

class CopyToClipboardCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            setAppleScriptError(.clipboardEmptyText, message: "Cannot copy empty text. Provide a non-empty string.")
            return nil
        }

        MainActor.assumeIsolated {
            ClipboardService.shared.copyToClipboard(text)
        }

        return nil
    }
}

// MARK: - Paste Text Command

class PasteTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            setAppleScriptError(.clipboardEmptyText, message: "Cannot paste empty text. Provide a non-empty string.")
            return nil
        }

        suspendExecution()

        Task { @MainActor in
            await ClipboardService.shared.copyAndPaste(text)
            self.resumeExecution(withResult: nil)
        }

        return nil
    }
}
