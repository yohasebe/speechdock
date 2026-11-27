import SwiftUI

/// An icon-only button in the speech panels: one symbol size, and a clickable
/// area larger than the symbol.
struct PanelIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.4))
    }
}

/// Smaller, decreases, shows and resets, and enlarges the panel text size.
struct PanelTextSizeControl: View {
    let appState: AppState
    @ObservedObject private var shortcuts = ShortcutSettingsManager.shared

    var body: some View {
        HStack(spacing: 0) {
            Button { appState.decreasePanelTextFontSize() } label: { Image(systemName: "minus") }
                .buttonStyle(PanelIconButtonStyle())
                .help("Decrease Font Size (\(shortcuts.shortcut(for: .fontSizeDecrease).displayString))")

            Button { appState.resetPanelTextFontSize() } label: {
                Text("\(Int(appState.panelTextFontSize))")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reset Font Size (\(shortcuts.shortcut(for: .fontSizeReset).displayString))")

            Button { appState.increasePanelTextFontSize() } label: { Image(systemName: "plus") }
                .buttonStyle(PanelIconButtonStyle())
                .help("Increase Font Size (\(shortcuts.shortcut(for: .fontSizeIncrease).displayString))")
        }
    }
}

extension View {
    /// The small bar of text-area actions floating over a panel's text area.
    func panelTextToolbar() -> some View {
        self
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}
