import SwiftUI
import Carbon.HIToolbox

/// Represents a customizable keyboard shortcut
struct CustomShortcut: Codable, Equatable {
    var keyCode: Int  // Virtual key code
    var modifiers: UInt  // Modifier flags (command, shift, option, control)

    init(keyCode: Int = 0, modifiers: UInt = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Create from KeyEquivalent and SwiftUI.EventModifiers
    init(key: String, modifiers: SwiftUI.EventModifiers) {
        self.keyCode = Self.keyCodeFromString(key)
        self.modifiers = Self.modifiersToUInt(modifiers)
    }

    /// Convert to SwiftUI KeyEquivalent
    var keyEquivalent: KeyEquivalent? {
        guard let char = Self.stringFromKeyCode(keyCode) else { return nil }
        if char == "↩" || keyCode == kVK_Return {
            return .return
        } else if char == "⎋" || keyCode == kVK_Escape {
            return .escape
        } else if char == "⌫" || keyCode == kVK_Delete {
            return .delete
        } else if char == "⇥" || keyCode == kVK_Tab {
            return .tab
        } else if char == "␣" || keyCode == kVK_Space {
            return .space
        } else if let firstChar = char.lowercased().first {
            return KeyEquivalent(firstChar)
        }
        return nil
    }

    /// Convert to SwiftUI EventModifiers
    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers & UInt(NSEvent.ModifierFlags.command.rawValue) != 0 {
            result.insert(.command)
        }
        if modifiers & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0 {
            result.insert(.shift)
        }
        if modifiers & UInt(NSEvent.ModifierFlags.option.rawValue) != 0 {
            result.insert(.option)
        }
        if modifiers & UInt(NSEvent.ModifierFlags.control.rawValue) != 0 {
            result.insert(.control)
        }
        return result
    }

    /// Display string for the shortcut
    var displayString: String {
        var parts: [String] = []

        if modifiers & UInt(NSEvent.ModifierFlags.control.rawValue) != 0 {
            parts.append("⌃")
        }
        if modifiers & UInt(NSEvent.ModifierFlags.option.rawValue) != 0 {
            parts.append("⌥")
        }
        if modifiers & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0 {
            parts.append("⇧")
        }
        if modifiers & UInt(NSEvent.ModifierFlags.command.rawValue) != 0 {
            parts.append("⌘")
        }

        if let keyString = Self.stringFromKeyCode(keyCode) {
            parts.append(keyString)
        }

        return parts.joined()
    }

    /// Check if shortcut is valid (has at least command modifier and a key)
    var isValid: Bool {
        keyCode != 0 && modifiers != 0
    }

    // MARK: - Key Code Conversion

    private static func keyCodeFromString(_ str: String) -> Int {
        let key = str.lowercased()
        switch key {
        case "a": return kVK_ANSI_A
        case "b": return kVK_ANSI_B
        case "c": return kVK_ANSI_C
        case "d": return kVK_ANSI_D
        case "e": return kVK_ANSI_E
        case "f": return kVK_ANSI_F
        case "g": return kVK_ANSI_G
        case "h": return kVK_ANSI_H
        case "i": return kVK_ANSI_I
        case "j": return kVK_ANSI_J
        case "k": return kVK_ANSI_K
        case "l": return kVK_ANSI_L
        case "m": return kVK_ANSI_M
        case "n": return kVK_ANSI_N
        case "o": return kVK_ANSI_O
        case "p": return kVK_ANSI_P
        case "q": return kVK_ANSI_Q
        case "r": return kVK_ANSI_R
        case "s": return kVK_ANSI_S
        case "t": return kVK_ANSI_T
        case "u": return kVK_ANSI_U
        case "v": return kVK_ANSI_V
        case "w": return kVK_ANSI_W
        case "x": return kVK_ANSI_X
        case "y": return kVK_ANSI_Y
        case "z": return kVK_ANSI_Z
        case "0": return kVK_ANSI_0
        case "1": return kVK_ANSI_1
        case "2": return kVK_ANSI_2
        case "3": return kVK_ANSI_3
        case "4": return kVK_ANSI_4
        case "5": return kVK_ANSI_5
        case "6": return kVK_ANSI_6
        case "7": return kVK_ANSI_7
        case "8": return kVK_ANSI_8
        case "9": return kVK_ANSI_9
        default: return 0
        }
    }

    static func stringFromKeyCode(_ keyCode: Int) -> String? {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "␣"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        default: return nil
        }
    }

    private static func modifiersToUInt(_ modifiers: SwiftUI.EventModifiers) -> UInt {
        var result: UInt = 0
        if modifiers.contains(.command) {
            result |= UInt(NSEvent.ModifierFlags.command.rawValue)
        }
        if modifiers.contains(.shift) {
            result |= UInt(NSEvent.ModifierFlags.shift.rawValue)
        }
        if modifiers.contains(.option) {
            result |= UInt(NSEvent.ModifierFlags.option.rawValue)
        }
        if modifiers.contains(.control) {
            result |= UInt(NSEvent.ModifierFlags.control.rawValue)
        }
        return result
    }
}

/// Identifiers for all customizable shortcuts
enum ShortcutAction: String, CaseIterable, Codable {
    // STT Panel shortcuts
    case sttRecord = "stt_record"
    case sttStop = "stt_stop"
    case sttPaste = "stt_paste"
    case sttSave = "stt_save"
    case sttTargetSelect = "stt_target_select"
    case sttCancel = "stt_cancel"

    // TTS Panel shortcuts
    case ttsSpeak = "tts_speak"
    case ttsStop = "tts_stop"
    case ttsSave = "tts_save"
    case ttsClose = "tts_close"

    var displayName: String {
        switch self {
        case .sttRecord: return "Record"
        case .sttStop: return "Stop Recording"
        case .sttPaste: return "Paste"
        case .sttSave: return "Save Text"
        case .sttTargetSelect: return "Select Target"
        case .sttCancel: return "Cancel"
        case .ttsSpeak: return "Speak"
        case .ttsStop: return "Stop Speaking"
        case .ttsSave: return "Save Audio"
        case .ttsClose: return "Close"
        }
    }

    var category: String {
        switch self {
        case .sttRecord, .sttStop, .sttPaste, .sttSave, .sttTargetSelect, .sttCancel:
            return "STT Panel"
        case .ttsSpeak, .ttsStop, .ttsSave, .ttsClose:
            return "TTS Panel"
        }
    }

    /// Default shortcut for this action
    var defaultShortcut: CustomShortcut {
        switch self {
        case .sttRecord:
            return CustomShortcut(key: "r", modifiers: .command)
        case .sttStop:
            return CustomShortcut(key: "s", modifiers: .command)
        case .sttPaste:
            return CustomShortcut(keyCode: kVK_Return, modifiers: UInt(NSEvent.ModifierFlags.command.rawValue))
        case .sttSave:
            return CustomShortcut(key: "s", modifiers: [.command, .shift])
        case .sttTargetSelect:
            return CustomShortcut(keyCode: kVK_Return, modifiers: UInt(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue))
        case .sttCancel:
            return CustomShortcut(keyCode: kVK_ANSI_Period, modifiers: UInt(NSEvent.ModifierFlags.command.rawValue))
        case .ttsSpeak:
            return CustomShortcut(keyCode: kVK_Return, modifiers: UInt(NSEvent.ModifierFlags.command.rawValue))
        case .ttsStop:
            return CustomShortcut(keyCode: kVK_ANSI_Period, modifiers: UInt(NSEvent.ModifierFlags.command.rawValue))
        case .ttsSave:
            return CustomShortcut(key: "s", modifiers: .command)
        case .ttsClose:
            return CustomShortcut(keyCode: kVK_ANSI_Period, modifiers: UInt(NSEvent.ModifierFlags.command.rawValue))
        }
    }
}

/// Manager for keyboard shortcut settings
@MainActor
final class ShortcutSettingsManager: ObservableObject {
    static let shared = ShortcutSettingsManager()

    @Published private(set) var shortcuts: [ShortcutAction: CustomShortcut] = [:]

    private let userDefaultsKey = "customKeyboardShortcuts"

    private init() {
        loadShortcuts()
    }

    /// Get shortcut for an action (returns default if not customized)
    func shortcut(for action: ShortcutAction) -> CustomShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// Set custom shortcut for an action
    func setShortcut(_ shortcut: CustomShortcut, for action: ShortcutAction) {
        shortcuts[action] = shortcut
        saveShortcuts()
    }

    /// Reset shortcut to default
    func resetShortcut(for action: ShortcutAction) {
        shortcuts.removeValue(forKey: action)
        saveShortcuts()
    }

    /// Reset all shortcuts to defaults
    func resetAllShortcuts() {
        shortcuts.removeAll()
        saveShortcuts()
    }

    private func loadShortcuts() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: CustomShortcut].self, from: data) else {
            return
        }

        for (key, value) in decoded {
            if let action = ShortcutAction(rawValue: key) {
                shortcuts[action] = value
            }
        }
    }

    private func saveShortcuts() {
        let encoded: [String: CustomShortcut] = shortcuts.reduce(into: [:]) { result, pair in
            result[pair.key.rawValue] = pair.value
        }

        do {
            let data = try JSONEncoder().encode(encoded)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            #if DEBUG
            print("KeyboardShortcutSettings: Failed to save shortcuts: \(error)")
            #endif
        }
    }
}
