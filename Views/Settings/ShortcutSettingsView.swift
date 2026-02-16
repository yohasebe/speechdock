import SwiftUI
import Carbon.HIToolbox

struct ShortcutSettingsView: View {
    @Environment(AppState.self) var appState
    @State private var sttKeyCombo: KeyCombo = .sttDefault
    @State private var ttsKeyCombo: KeyCombo = .ttsDefault
    @State private var ocrKeyCombo: KeyCombo = .ocrDefault
    @State private var subtitleKeyCombo: KeyCombo = .subtitleDefault
    @State private var shortcutHUDKeyCombo: KeyCombo = .shortcutHUDDefault
    @State private var quickTranscriptionKeyCombo: KeyCombo = .quickTranscriptionDefault
    @StateObject private var shortcutManager = ShortcutSettingsManager.shared

    var body: some View {
        ScrollView {
            Form {
                Section {
                    ShortcutRecorderView(title: NSLocalizedString("Toggle STT Panel", comment: "Hotkey"), keyCombo: $sttKeyCombo)
                        .onChange(of: sttKeyCombo) { _, newValue in
                            appState.hotKeyService?.sttKeyCombo = newValue
                        }

                    ShortcutRecorderView(title: NSLocalizedString("Toggle TTS Panel", comment: "Hotkey"), keyCombo: $ttsKeyCombo)
                        .onChange(of: ttsKeyCombo) { _, newValue in
                            appState.hotKeyService?.ttsKeyCombo = newValue
                        }

                    ShortcutRecorderView(title: NSLocalizedString("OCR Region to TTS", comment: "Hotkey"), keyCombo: $ocrKeyCombo)
                        .onChange(of: ocrKeyCombo) { _, newValue in
                            appState.hotKeyService?.ocrKeyCombo = newValue
                        }

                    ShortcutRecorderView(title: NSLocalizedString("Toggle Subtitle Mode", comment: "Hotkey"), keyCombo: $subtitleKeyCombo)
                        .onChange(of: subtitleKeyCombo) { _, newValue in
                            appState.hotKeyService?.subtitleKeyCombo = newValue
                        }

                    ShortcutRecorderView(title: NSLocalizedString("Show Shortcuts", comment: "Hotkey"), keyCombo: $shortcutHUDKeyCombo)
                        .onChange(of: shortcutHUDKeyCombo) { _, newValue in
                            appState.hotKeyService?.shortcutHUDKeyCombo = newValue
                        }

                    ShortcutRecorderView(title: NSLocalizedString("Quick Transcription", comment: "Hotkey"), keyCombo: $quickTranscriptionKeyCombo)
                        .onChange(of: quickTranscriptionKeyCombo) { _, newValue in
                            appState.hotKeyService?.quickTranscriptionKeyCombo = newValue
                        }
                } header: {
                    Text("Global Hotkeys")
                } footer: {
                    Text("Click on a shortcut and press a new key combination to change it. Shortcuts must include at least one modifier key (\u{2318}, \u{2325}, \u{2303}, or \u{21E7}).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    ForEach(ShortcutAction.allCases.filter { $0.category == "STT Panel" }, id: \.self) { action in
                        PanelShortcutRow(action: action, manager: shortcutManager)
                    }
                } header: {
                    Text("STT Panel Shortcuts")
                } footer: {
                    Text("Shortcuts available when the STT transcription panel is open.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    ForEach(ShortcutAction.allCases.filter { $0.category == "TTS Panel" }, id: \.self) { action in
                        PanelShortcutRow(action: action, manager: shortcutManager)
                    }
                } header: {
                    Text("TTS Panel Shortcuts")
                } footer: {
                    Text("Shortcuts available when the TTS panel is open. STT and TTS panels are mutually exclusive, so they can share the same shortcuts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    ForEach(ShortcutAction.allCases.filter { $0.category == "Common" }, id: \.self) { action in
                        PanelShortcutRow(action: action, manager: shortcutManager)
                    }
                } header: {
                    Text("Common Shortcuts")
                } footer: {
                    Text("Shortcuts available in both STT and TTS panels.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("Reset Global Hotkeys") {
                        sttKeyCombo = .sttDefault
                        ttsKeyCombo = .ttsDefault
                        ocrKeyCombo = .ocrDefault
                        subtitleKeyCombo = .subtitleDefault
                        shortcutHUDKeyCombo = .shortcutHUDDefault
                        appState.hotKeyService?.sttKeyCombo = .sttDefault
                        appState.hotKeyService?.ttsKeyCombo = .ttsDefault
                        appState.hotKeyService?.ocrKeyCombo = .ocrDefault
                        appState.hotKeyService?.subtitleKeyCombo = .subtitleDefault
                        appState.hotKeyService?.shortcutHUDKeyCombo = .shortcutHUDDefault
                    }

                    Button("Reset Panel Shortcuts") {
                        shortcutManager.resetAllShortcuts()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .scrollIndicators(.visible)
        .onAppear {
            if let service = appState.hotKeyService {
                sttKeyCombo = service.sttKeyCombo
                ttsKeyCombo = service.ttsKeyCombo
                ocrKeyCombo = service.ocrKeyCombo
                subtitleKeyCombo = service.subtitleKeyCombo
                shortcutHUDKeyCombo = service.shortcutHUDKeyCombo
                quickTranscriptionKeyCombo = service.quickTranscriptionKeyCombo
            }
        }
    }
}

// MARK: - Shortcut Component Views

/// Row for editing a panel shortcut
struct PanelShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var manager: ShortcutSettingsManager
    @State private var isRecording = false

    private var currentShortcut: CustomShortcut {
        manager.shortcut(for: action)
    }

    var body: some View {
        HStack {
            Text(action.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            PanelShortcutRecorder(
                shortcut: currentShortcut,
                isRecording: $isRecording,
                onRecord: { newShortcut in
                    manager.setShortcut(newShortcut, for: action)
                }
            )
            .frame(width: 120)

            Button(action: {
                manager.resetShortcut(for: action)
            }) {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
        }
    }
}

/// Shortcut recorder for panel shortcuts (captures key + modifiers)
struct PanelShortcutRecorder: View {
    let shortcut: CustomShortcut
    @Binding var isRecording: Bool
    let onRecord: (CustomShortcut) -> Void

    var body: some View {
        Button(action: {
            isRecording = true
        }) {
            Text(isRecording ? "Press keys..." : shortcut.displayString)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .focusable()
        .onKeyPress { keyPress in
            guard isRecording else { return .ignored }

            var modifiers: UInt = 0
            if keyPress.modifiers.contains(.command) {
                modifiers |= UInt(NSEvent.ModifierFlags.command.rawValue)
            }
            if keyPress.modifiers.contains(.shift) {
                modifiers |= UInt(NSEvent.ModifierFlags.shift.rawValue)
            }
            if keyPress.modifiers.contains(.option) {
                modifiers |= UInt(NSEvent.ModifierFlags.option.rawValue)
            }
            if keyPress.modifiers.contains(.control) {
                modifiers |= UInt(NSEvent.ModifierFlags.control.rawValue)
            }

            let keyCode = keyCodeFromKeyEquivalent(keyPress.key)

            if modifiers != 0 || isSpecialKey(keyCode) {
                let newShortcut = CustomShortcut(keyCode: keyCode, modifiers: modifiers)
                if newShortcut.isValid {
                    onRecord(newShortcut)
                }
            }

            isRecording = false
            return .handled
        }
        .onExitCommand {
            isRecording = false
        }
    }

    private func keyCodeFromKeyEquivalent(_ key: KeyEquivalent) -> Int {
        let char = String(key.character).lowercased()

        switch char {
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
        case ".": return kVK_ANSI_Period
        case ",": return kVK_ANSI_Comma
        case "/": return kVK_ANSI_Slash
        case ";": return kVK_ANSI_Semicolon
        case "=": return kVK_ANSI_Equal
        case "-": return kVK_ANSI_Minus
        case "\r", "\n": return kVK_Return
        case "\u{1B}": return kVK_Escape
        case "\u{7F}": return kVK_Delete
        case "\t": return kVK_Tab
        case " ": return kVK_Space
        default: return 0
        }
    }

    private func isSpecialKey(_ keyCode: Int) -> Bool {
        return keyCode == kVK_Return ||
               keyCode == kVK_Escape ||
               keyCode == kVK_Delete ||
               keyCode == kVK_Tab ||
               keyCode == kVK_Space
    }
}
