import SwiftUI

struct ShortcutHUDView: View {
    let hotKeyService: HotKeyService?
    let shortcutManager: ShortcutSettingsManager
    let dismissShortcutString: String
    let globalActions: [String: () -> Void]

    var body: some View {
        VStack(spacing: 20) {
            // Header: App icon + name + title
            HStack(spacing: 10) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("SpeechDock")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
                Spacer()
            }

            Divider()
                .overlay(Color.white.opacity(0.2))

            // Two-column layout
            HStack(alignment: .top, spacing: 32) {
                // Left column: Global + STT Panel
                VStack(alignment: .leading, spacing: 16) {
                    ShortcutSection(title: "Global Hotkeys", items: globalShortcuts)
                    ShortcutSection(title: "STT Panel", items: sttPanelShortcuts)
                }

                // Right column: TTS Panel + Common
                VStack(alignment: .leading, spacing: 16) {
                    ShortcutSection(title: "TTS Panel", items: ttsPanelShortcuts)
                    ShortcutSection(title: "Common", items: commonShortcuts)
                }
            }

            // Footer
            Text("Press ESC or \(dismissShortcutString) to dismiss")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }

    // MARK: - Shortcut Data

    private var globalShortcuts: [ShortcutItem] {
        guard let service = hotKeyService else { return [] }
        return [
            ShortcutItem(name: "Toggle STT Panel", shortcut: service.sttKeyCombo.displayString, action: globalActions["toggleSTT"]),
            ShortcutItem(name: "Toggle TTS Panel", shortcut: service.ttsKeyCombo.displayString, action: globalActions["toggleTTS"]),
            ShortcutItem(name: "OCR Region to TTS", shortcut: service.ocrKeyCombo.displayString, action: globalActions["ocr"]),
            ShortcutItem(name: "Toggle Subtitle Mode", shortcut: service.subtitleKeyCombo.displayString, action: globalActions["subtitle"]),
            ShortcutItem(name: "Quick Transcription", shortcut: service.quickTranscriptionKeyCombo.displayString, action: globalActions["quickTranscription"]),
            ShortcutItem(name: "Show Shortcuts", shortcut: service.shortcutHUDKeyCombo.displayString),
        ]
    }

    private var sttPanelShortcuts: [ShortcutItem] {
        ShortcutAction.allCases
            .filter { $0.category == "STT Panel" }
            .map { action in
                ShortcutItem(
                    name: action.displayName,
                    shortcut: shortcutManager.shortcut(for: action).displayString
                )
            }
    }

    private var ttsPanelShortcuts: [ShortcutItem] {
        ShortcutAction.allCases
            .filter { $0.category == "TTS Panel" }
            .map { action in
                ShortcutItem(
                    name: action.displayName,
                    shortcut: shortcutManager.shortcut(for: action).displayString
                )
            }
    }

    private var commonShortcuts: [ShortcutItem] {
        ShortcutAction.allCases
            .filter { $0.category == "Common" }
            .map { action in
                ShortcutItem(
                    name: action.displayName,
                    shortcut: shortcutManager.shortcut(for: action).displayString
                )
            }
    }
}

// MARK: - Supporting Views

struct ShortcutSection: View {
    let title: String
    let items: [ShortcutItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
                .padding(.bottom, 3)

            ForEach(items) { item in
                ShortcutRow(item: item)
            }
        }
    }
}

struct ShortcutRow: View {
    let item: ShortcutItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            Text(item.name)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .frame(minWidth: 140, alignment: .leading)

            Spacer(minLength: 4)

            Text(item.shortcut)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.15))
                .cornerRadius(4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered && item.action != nil ? Color.white.opacity(0.1) : Color.clear)
        )
        .onHover { hovering in
            if item.action != nil {
                isHovered = hovering
            }
        }
        .onTapGesture {
            item.action?()
        }
        .help(item.action != nil ? "Click to execute" : "")
    }
}

struct ShortcutItem: Identifiable {
    let id = UUID()
    let name: String
    let shortcut: String
    var action: (() -> Void)? = nil
}
