import AppKit
import SwiftUI
import Combine

/// Manages the menu bar status item with dynamic icon colors and pulse animation
@MainActor
final class StatusBarManager: NSObject {
    static let shared = StatusBarManager()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var observationTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?
    private weak var appState: AppState?

    /// Whether the menu bar panel is currently visible
    var isPanelVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Event monitor for clicks outside the panel
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var keyEventMonitor: Any?

    /// Animation phase for pulsing effect (0.0 to 1.0)
    private var animationPhase: Double = 0.0
    /// Whether animation is currently running
    private var isAnimating = false

    private override init() {
        super.init()
    }

    func setup(appState: AppState) {
        self.appState = appState

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Set initial icon
        updateIcon(for: appState, animated: false)

        // Setup button action
        if let button = statusItem?.button {
            button.action = #selector(togglePanel)
            button.target = self
        }

        // Create panel
        createPanel(appState: appState)

        // Observe state changes using a periodic check
        startObservingState(appState: appState)
    }

    private func createPanel(appState: AppState) {
        // Create a borderless panel that can receive keyboard events
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        // Create SwiftUI content with rounded background
        let contentView = MenuBarPanelContainer {
            MenuBarView().environment(appState)
        }

        let hostingView = NSHostingView(rootView: AnyView(contentView))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        panel.contentView = hostingView
        self.hostingView = hostingView
        self.panel = panel
    }

    private func startObservingState(appState: AppState) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            var lastState = self?.getCurrentIconState(for: appState)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

                guard let self = self else { break }

                let newState = self.getCurrentIconState(for: appState)
                if newState != lastState {
                    lastState = newState

                    // Start or stop animation based on state
                    let needsAnimation = newState == 1 || newState == 3 // recording or speaking
                    if needsAnimation && !self.isAnimating {
                        self.startPulseAnimation(appState: appState)
                    } else if !needsAnimation && self.isAnimating {
                        self.stopPulseAnimation()
                        self.updateIcon(for: appState, animated: false)
                    } else if !needsAnimation {
                        self.updateIcon(for: appState, animated: false)
                    }
                }
            }
        }
    }

    /// Start the pulse animation for recording/speaking states
    private func startPulseAnimation(appState: AppState) {
        guard !isAnimating else { return }
        isAnimating = true
        animationPhase = 0.0

        animationTask?.cancel()
        animationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isAnimating else { break }

                // Update animation phase using sine wave for smooth pulsing
                self.animationPhase += 0.08
                if self.animationPhase > .pi * 2 {
                    self.animationPhase = 0
                }

                self.updateIcon(for: appState, animated: true)

                // ~30fps animation
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    /// Stop the pulse animation
    private func stopPulseAnimation() {
        isAnimating = false
        animationTask?.cancel()
        animationTask = nil
        animationPhase = 0.0
    }

    private func getCurrentIconState(for appState: AppState) -> Int {
        if appState.isRecording { return 1 }
        if appState.transcriptionState == .processing { return 2 }
        if appState.ttsState == .speaking { return 3 }
        if appState.ttsState == .loading { return 4 }
        return 0
    }

    private func updateIcon(for appState: AppState, animated: Bool) {
        guard let button = statusItem?.button else { return }

        // Load the template image
        guard let image = NSImage(named: "MenuBarIcon") else { return }
        image.isTemplate = false

        // Determine the color based on state
        let color: NSColor
        if appState.isRecording {
            let pulseAlpha = animated ? 0.5 + 0.5 * sin(animationPhase) : 1.0
            color = NSColor.systemRed.withAlphaComponent(CGFloat(pulseAlpha))
        } else if appState.transcriptionState == .processing {
            color = NSColor.systemRed.withAlphaComponent(0.6)
        } else if appState.ttsState == .speaking {
            let pulseAlpha = animated ? 0.5 + 0.5 * sin(animationPhase) : 1.0
            color = NSColor.systemBlue.withAlphaComponent(CGFloat(pulseAlpha))
        } else if appState.ttsState == .loading {
            color = NSColor.systemBlue.withAlphaComponent(0.6)
        } else {
            image.isTemplate = true
            button.image = image
            return
        }

        let tintedImage = tintImage(image, with: color)
        button.image = tintedImage
    }

    private func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        let size = image.size
        let newImage = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect,
                       from: rect,
                       operation: .sourceOver,
                       fraction: 1.0)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        newImage.isTemplate = false
        return newImage
    }

    // MARK: - Panel Toggle

    @objc private func togglePanel() {
        guard let panel = panel else { return }

        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel = panel, let button = statusItem?.button else { return }

        // Get the button's screen position
        guard let buttonWindow = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        // Position panel below the menu bar icon, centered
        let panelWidth = panel.frame.width
        let panelX = screenRect.midX - panelWidth / 2
        let panelY = screenRect.minY - panel.frame.height - 4

        // Update level dynamically so this panel appears above other panels
        panel.level = WindowLevelCoordinator.shared.nextPanelLevel()

        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.makeKeyAndOrderFront(nil)

        // Remove initial focus from first button
        panel.makeFirstResponder(nil)

        // Add event monitors to close when clicking outside
        addEventMonitors()
    }

    func closePanel() {
        panel?.orderOut(nil)
        removeEventMonitors()
        WindowLevelCoordinator.shared.reset()
    }

    // Alias for compatibility
    func closePopover() {
        closePanel()
    }

    // MARK: - Event Monitors

    private func addEventMonitors() {
        // Monitor for clicks outside the panel (global)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }

        // Monitor for clicks inside our app but outside the panel
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let panel = self.panel else { return event }

            // Check if click is inside the panel
            if let contentView = panel.contentView {
                let locationInWindow = event.locationInWindow
                let locationInPanel = contentView.convert(locationInWindow, from: nil)
                if !contentView.bounds.contains(locationInPanel) {
                    // Click is outside panel but inside app - close if not on status item
                    if event.window != self.statusItem?.button?.window {
                        self.closePanel()
                    }
                }
            }
            return event
        }

        // Monitor for ⌘, to open Settings (panel is nonactivatingPanel so app menu shortcuts don't work)
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
                self?.closePanel()
                WindowManager.shared.openSettingsWindow()
                return nil // consume the event
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    deinit {
        observationTask?.cancel()
        animationTask?.cancel()
        // Clean up event monitors - must be done on main thread
        let globalMonitor = globalEventMonitor
        let localMonitor = localEventMonitor
        let keyMonitor = keyEventMonitor
        if globalMonitor != nil || localMonitor != nil || keyMonitor != nil {
            DispatchQueue.main.async {
                if let monitor = globalMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                if let monitor = localMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                if let monitor = keyMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
        }
    }
}

// MARK: - Keyable Panel

/// NSPanel subclass that can become key to receive keyboard events
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Panel Container View

/// Container view for menu bar panel with rounded corners and shadow
struct MenuBarPanelContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.1)
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            legacyStyledContent
        }
        #else
        legacyStyledContent
        #endif
    }

    private var legacyStyledContent: some View {
        content
            .background(
                ZStack {
                    MenuBarVisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                            ? NSColor(white: 0.18, alpha: 0.85)
                            : NSColor(white: 0.96, alpha: 0.85)
                    }))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

/// NSVisualEffectView wrapper for menu bar panel
private struct MenuBarVisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
