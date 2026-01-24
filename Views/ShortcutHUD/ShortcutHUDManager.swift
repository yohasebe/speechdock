import AppKit
import SwiftUI

@MainActor
final class ShortcutHUDManager {
    static let shared = ShortcutHUDManager()

    private var panel: NSPanel?
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var clickOutsideMonitor: Any?

    /// Window level: above panels, below subtitle overlay (screenSaver - 1)
    private static let hudWindowLevel = NSWindow.Level(rawValue: Int(NSWindow.Level.screenSaver.rawValue) - 2)

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private init() {}

    func toggle(hotKeyService: HotKeyService?, shortcutManager: ShortcutSettingsManager, globalActions: [String: () -> Void] = [:]) {
        if isVisible {
            dismiss()
        } else {
            show(hotKeyService: hotKeyService, shortcutManager: shortcutManager, globalActions: globalActions)
        }
    }

    func show(hotKeyService: HotKeyService?, shortcutManager: ShortcutSettingsManager, globalActions: [String: () -> Void] = [:]) {
        // Dismiss any existing panel
        dismiss()

        let dismissString = hotKeyService?.shortcutHUDKeyCombo.displayString ?? "⌃⌥/"

        // Wrap actions to dismiss HUD before executing
        let wrappedActions = globalActions.mapValues { action in
            return { [weak self] in
                self?.dismiss()
                action()
            }
        }

        let hudView = ShortcutHUDView(
            hotKeyService: hotKeyService,
            shortcutManager: shortcutManager,
            dismissShortcutString: dismissString,
            globalActions: wrappedActions
        )

        let hostingView = NSHostingView(rootView: hudView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let panelSize = hostingView.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = Self.hudWindowLevel
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Center on main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelSize.width / 2
            let y = screenFrame.midY - panelSize.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel

        setupEventMonitors()
    }

    func dismiss() {
        removeEventMonitors()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Event Monitors

    private func setupEventMonitors() {
        // Local ESC key monitor
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.dismiss()
                return nil
            }
            return event
        }

        // Global ESC key monitor (when app is not focused)
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                Task { @MainActor in
                    self?.dismiss()
                }
            }
        }

        // Click outside monitor
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    private func removeEventMonitors() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
