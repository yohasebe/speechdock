import AppKit
import SwiftUI

/// A small HUD panel that shows transcription text in real-time
/// Used when direct text insertion is not available
@MainActor
final class FloatingMicTextHUD {
    static let shared = FloatingMicTextHUD()

    private var hudWindow: NSWindow?
    private var textObservation: NSKeyValueObservation?

    private let hudWidth: CGFloat = 300
    private let hudHeight: CGFloat = 60
    private let cornerRadius: CGFloat = 12

    private init() {}

    // MARK: - Show/Hide

    var isVisible: Bool {
        hudWindow != nil
    }

    func show(near buttonFrame: NSRect) {
        guard hudWindow == nil else { return }

        // Position HUD above the floating button
        let hudFrame = NSRect(
            x: buttonFrame.midX - hudWidth / 2,
            y: buttonFrame.maxY + 10,
            width: hudWidth,
            height: hudHeight
        )

        // Adjust if off screen
        let adjustedFrame = adjustFrameToScreen(hudFrame)

        let window = NSPanel(
            contentRect: adjustedFrame,
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

        let contentView = FloatingMicTextHUDView()
        window.contentView = NSHostingView(rootView: contentView)
        window.orderFrontRegardless()

        self.hudWindow = window
    }

    func hide() {
        hudWindow?.orderOut(nil)
        hudWindow = nil
    }

    func updatePosition(near buttonFrame: NSRect) {
        guard let window = hudWindow else { return }

        let hudFrame = NSRect(
            x: buttonFrame.midX - hudWidth / 2,
            y: buttonFrame.maxY + 10,
            width: hudWidth,
            height: hudHeight
        )

        let adjustedFrame = adjustFrameToScreen(hudFrame)
        window.setFrame(adjustedFrame, display: true)
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
            // Show below the button instead
            adjusted.origin.y = frame.minY - hudHeight - 60
        }
        if adjusted.minY < screenFrame.minY {
            adjusted.origin.y = screenFrame.minY + 10
        }

        return adjusted
    }
}

// MARK: - HUD View

struct FloatingMicTextHUDView: View {
    @State private var text: String = ""

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)

            // Content
            HStack(spacing: 8) {
                // Recording indicator
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)

                // Text
                Text(text.isEmpty ? "Listening..." : text)
                    .font(.system(size: 14))
                    .foregroundColor(text.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingMicTranscriptionUpdated)) { notification in
            if let newText = notification.object as? String {
                withAnimation(.easeInOut(duration: 0.1)) {
                    text = newText
                }
            }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let floatingMicTranscriptionUpdated = Notification.Name("floatingMicTranscriptionUpdated")
}
