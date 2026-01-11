import AppKit
import HotKey
import os.log

private let logger = Logger(subsystem: "com.typetalk", category: "HotKey")

protocol HotKeyServiceDelegate: AnyObject {
    func hotKeyPressed()
    func ttsHotKeyPressed()
}

final class HotKeyService {
    private var sttHotKey: HotKey?
    private var ttsHotKey: HotKey?
    private var isLoadingShortcuts = false

    weak var delegate: HotKeyServiceDelegate?

    var sttKeyCombo: KeyCombo {
        didSet {
            guard !isLoadingShortcuts else { return }
            saveShortcuts()
            registerHotKey()
        }
    }

    var ttsKeyCombo: KeyCombo {
        didSet {
            guard !isLoadingShortcuts else { return }
            saveShortcuts()
            registerTTSHotKey()
        }
    }

    init() {
        // Load saved shortcuts or use defaults
        self.sttKeyCombo = KeyCombo.sttDefault
        self.ttsKeyCombo = KeyCombo.ttsDefault
        loadShortcuts()
    }

    func registerHotKey() {
        // Remove existing hotkey
        sttHotKey = nil

        // Create new hotkey
        sttHotKey = HotKey(key: sttKeyCombo.key, modifiers: sttKeyCombo.modifiers)
        logger.info("STT HotKey registered: \(self.sttKeyCombo.displayString)")

        sttHotKey?.keyDownHandler = { [weak self] in
            logger.info("STT HotKey pressed!")
            self?.delegate?.hotKeyPressed()
        }
    }

    func registerTTSHotKey() {
        // Remove existing hotkey
        ttsHotKey = nil

        // Create new hotkey
        ttsHotKey = HotKey(key: ttsKeyCombo.key, modifiers: ttsKeyCombo.modifiers)
        logger.info("TTS HotKey registered: \(self.ttsKeyCombo.displayString)")

        ttsHotKey?.keyDownHandler = { [weak self] in
            logger.info("TTS HotKey pressed!")
            self?.delegate?.ttsHotKeyPressed()
        }
    }

    func registerAllHotKeys() {
        registerHotKey()
        registerTTSHotKey()
    }

    func unregisterAllHotKeys() {
        sttHotKey = nil
        ttsHotKey = nil
    }

    // MARK: - Persistence

    private func loadShortcuts() {
        isLoadingShortcuts = true
        defer { isLoadingShortcuts = false }

        let defaults = UserDefaults.standard

        // Load STT shortcut
        if let sttKeyCode = defaults.object(forKey: "sttKeyCode") as? UInt32,
           let sttModifiers = defaults.object(forKey: "sttModifiers") as? UInt,
           let key = Key(carbonKeyCode: sttKeyCode) {
            sttKeyCombo = KeyCombo(key: key, modifiers: NSEvent.ModifierFlags(rawValue: sttModifiers))
        }

        // Load TTS shortcut
        if let ttsKeyCode = defaults.object(forKey: "ttsKeyCode") as? UInt32,
           let ttsModifiers = defaults.object(forKey: "ttsModifiers") as? UInt,
           let key = Key(carbonKeyCode: ttsKeyCode) {
            ttsKeyCombo = KeyCombo(key: key, modifiers: NSEvent.ModifierFlags(rawValue: ttsModifiers))
        }
    }

    private func saveShortcuts() {
        let defaults = UserDefaults.standard

        // Save STT shortcut
        defaults.set(sttKeyCombo.key.carbonKeyCode, forKey: "sttKeyCode")
        defaults.set(sttKeyCombo.modifiers.rawValue, forKey: "sttModifiers")

        // Save TTS shortcut
        defaults.set(ttsKeyCombo.key.carbonKeyCode, forKey: "ttsKeyCode")
        defaults.set(ttsKeyCombo.modifiers.rawValue, forKey: "ttsModifiers")
    }
}

struct KeyCombo: Equatable {
    let key: Key
    let modifiers: NSEvent.ModifierFlags

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }

        // Get key name
        let keyName: String
        switch key {
        case .space: keyName = "Space"
        case .return: keyName = "↩"
        case .tab: keyName = "⇥"
        case .escape: keyName = "⎋"
        case .delete: keyName = "⌫"
        case .upArrow: keyName = "↑"
        case .downArrow: keyName = "↓"
        case .leftArrow: keyName = "←"
        case .rightArrow: keyName = "→"
        default: keyName = key.description.uppercased()
        }

        parts.append(keyName)
        return parts.joined()
    }

    static let sttDefault = KeyCombo(key: .space, modifiers: [.command, .shift])
    static let ttsDefault = KeyCombo(key: .t, modifiers: [.control, .option])
}

// MARK: - Shortcut Recorder View

import SwiftUI

struct ShortcutRecorderView: View {
    let title: String
    @Binding var keyCombo: KeyCombo
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(title)

            Spacer()

            Button(action: {
                isRecording.toggle()
            }) {
                if isRecording {
                    Text("Press shortcut...")
                        .foregroundColor(.accentColor)
                        .frame(minWidth: 120)
                } else {
                    Text(keyCombo.displayString)
                        .frame(minWidth: 120)
                }
            }
            .buttonStyle(.bordered)
            .background(
                ShortcutRecorderEventHandler(
                    isRecording: $isRecording,
                    keyCombo: $keyCombo
                )
            )
        }
    }
}

struct ShortcutRecorderEventHandler: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var keyCombo: KeyCombo

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onKeyDown = { event in
            guard isRecording else { return false }

            // Require at least one modifier
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !modifiers.isEmpty else { return false }

            // Get key from event
            if let key = Key(carbonKeyCode: UInt32(event.keyCode)) {
                keyCombo = KeyCombo(key: key, modifiers: modifiers)
                isRecording = false
                return true
            }

            return false
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.isRecording = isRecording
    }
}

class ShortcutRecorderNSView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var isRecording = false {
        didSet {
            if isRecording {
                window?.makeFirstResponder(self)
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let onKeyDown = onKeyDown, onKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // Cancel recording if Escape is pressed
        if event.keyCode == 53 { // Escape key code
            isRecording = false
        }
        super.flagsChanged(with: event)
    }
}
