import AppKit
import SwiftUI

/// A small HUD panel that shows transcription text in real-time
/// Draggable and semi-transparent like ShortcutHUD
@MainActor
final class FloatingMicTextHUD {
    static let shared = FloatingMicTextHUD()

    private var hudWindow: NSWindow?

    private let hudWidth: CGFloat = FloatingMicConstants.hudWidth
    private let hudHeight: CGFloat = FloatingMicConstants.hudHeight
    private let cornerRadius: CGFloat = 12

    /// Starting window position for drag
    private var dragStartOrigin: CGPoint?
    /// Starting mouse position for drag
    private var dragStartMouseLocation: CGPoint?

    private let positionKey = FloatingMicConstants.hudPositionKey

    private init() {}

    // MARK: - Show/Hide

    var isVisible: Bool {
        hudWindow != nil
    }

    func show(near buttonFrame: NSRect) {
        guard hudWindow == nil else { return }

        // Use saved position or default to above the button
        let hudFrame = savedFrameOrDefault(near: buttonFrame)

        let window = NSPanel(
            contentRect: hudFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating + 1
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let contentView = FloatingMicTextHUDView(manager: self)
        window.contentView = NSHostingView(rootView: contentView)
        window.orderFrontRegardless()

        self.hudWindow = window
    }

    func hide() {
        saveWindowPosition()
        hudWindow?.orderOut(nil)
        hudWindow = nil
    }

    // MARK: - Dragging

    func startDragging() {
        guard let window = hudWindow else { return }
        dragStartOrigin = window.frame.origin
        dragStartMouseLocation = NSEvent.mouseLocation
    }

    func continueDragging() {
        guard let window = hudWindow,
              let startOrigin = dragStartOrigin,
              let startMouse = dragStartMouseLocation else { return }

        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - startMouse.x
        let deltaY = currentMouse.y - startMouse.y

        let newOrigin = CGPoint(
            x: startOrigin.x + deltaX,
            y: startOrigin.y + deltaY
        )

        window.setFrameOrigin(newOrigin)
    }

    func finishDragging() {
        dragStartOrigin = nil
        dragStartMouseLocation = nil
        saveWindowPosition()
    }

    // MARK: - Position Persistence

    private func saveWindowPosition() {
        guard let frame = hudWindow?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: positionKey)
    }

    private func savedFrameOrDefault(near buttonFrame: NSRect) -> NSRect {
        // Try to use saved position
        if let frameString = UserDefaults.standard.string(forKey: positionKey) {
            let savedFrame = NSRectFromString(frameString)
            if savedFrame.width > 0 && savedFrame.height > 0 {
                // Validate position is on any connected screen
                let savedRect = NSRect(
                    x: savedFrame.origin.x,
                    y: savedFrame.origin.y,
                    width: hudWidth,
                    height: hudHeight
                )

                if let validatedRect = validatePositionOnConnectedScreens(savedRect) {
                    return validatedRect
                } else {
                    // Clear invalid saved position (screen was disconnected)
                    UserDefaults.standard.removeObject(forKey: positionKey)
                }
            }
        }

        // Default: position above the button
        let defaultFrame = NSRect(
            x: buttonFrame.midX - hudWidth / 2,
            y: buttonFrame.maxY + 10,
            width: hudWidth,
            height: hudHeight
        )

        return adjustFrameToScreen(defaultFrame)
    }

    /// Validates that a position is on a connected screen
    /// If the position is partially off-screen, it's adjusted to fit
    /// Returns nil if the position is completely off all screens
    private func validatePositionOnConnectedScreens(_ rect: NSRect) -> NSRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // Check if the rect intersects with any connected screen
        for screen in screens {
            let screenFrame = screen.visibleFrame
            if screenFrame.intersects(rect) {
                // Adjust to keep within this screen's bounds
                var adjusted = rect
                let margin = FloatingMicConstants.positionMargin

                if adjusted.maxX > screenFrame.maxX {
                    adjusted.origin.x = screenFrame.maxX - adjusted.width - margin
                }
                if adjusted.minX < screenFrame.minX {
                    adjusted.origin.x = screenFrame.minX + margin
                }
                if adjusted.maxY > screenFrame.maxY {
                    adjusted.origin.y = screenFrame.maxY - adjusted.height - margin
                }
                if adjusted.minY < screenFrame.minY {
                    adjusted.origin.y = screenFrame.minY + margin
                }

                return adjusted
            }
        }

        // Position is not on any connected screen
        return nil
    }

    private func adjustFrameToScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.main else { return frame }

        var adjusted = frame
        let screenFrame = screen.visibleFrame

        // Keep within screen bounds
        if adjusted.maxX > screenFrame.maxX {
            adjusted.origin.x = screenFrame.maxX - adjusted.width - 10
        }
        if adjusted.minX < screenFrame.minX {
            adjusted.origin.x = screenFrame.minX + 10
        }
        if adjusted.maxY > screenFrame.maxY {
            adjusted.origin.y = screenFrame.maxY - adjusted.height - 10
        }
        if adjusted.minY < screenFrame.minY {
            adjusted.origin.y = screenFrame.minY + 10
        }

        return adjusted
    }
}

// MARK: - HUD View

struct FloatingMicTextHUDView: View {
    let manager: FloatingMicTextHUD
    @State private var text: String = ""
    @State private var isDragging = false

    /// Height for each line of text
    private let lineHeight: CGFloat = FloatingMicConstants.hudLineHeight
    private let fontSize: CGFloat = FloatingMicConstants.hudFontSize
    private let maxLines: Int = FloatingMicConstants.hudMaxLines

    /// Shortcut display string
    private var shortcutString: String {
        AppState.shared.hotKeyService?.quickTranscriptionKeyCombo.displayString ?? "⌃⌥M"
    }

    /// Maximum height for the text area based on max lines
    private var maxTextHeight: CGFloat {
        lineHeight * CGFloat(maxLines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with recording indicator and stop shortcut
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                Text("(\(shortcutString) to stop)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
            }

            // Scrollable transcription text area
            if text.isEmpty {
                Text("Listening...")
                    .font(.system(size: fontSize))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("hudText")
                    }
                    .frame(maxHeight: maxTextHeight)
                    .mask(
                        // Fade out at the top when scrolled
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.15),
                                .init(color: .black, location: 1.0)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .onChange(of: text) { _, _ in
                        // Smooth scroll to bottom when text changes
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("hudText", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        // Initial scroll to bottom
                        proxy.scrollTo("hudText", anchor: .bottom)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.75))
        )
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    if !isDragging {
                        isDragging = true
                        manager.startDragging()
                    }
                    manager.continueDragging()
                }
                .onEnded { _ in
                    manager.finishDragging()
                    isDragging = false
                }
        )
        .onReceive(NotificationCenter.default.publisher(for: FloatingMicConstants.transcriptionUpdatedNotification)) { notification in
            if let newText = notification.object as? String {
                text = newText
            }
        }
    }
}

// MARK: - Notification (for backward compatibility)

extension Notification.Name {
    static let floatingMicTranscriptionUpdated = FloatingMicConstants.transcriptionUpdatedNotification
}
