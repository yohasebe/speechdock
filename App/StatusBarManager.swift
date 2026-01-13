import AppKit
import SwiftUI
import Combine

/// Manages the menu bar status item with dynamic icon colors and pulse animation
@MainActor
final class StatusBarManager: NSObject {
    static let shared = StatusBarManager()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var observationTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?

    /// Animation phase for pulsing effect (0.0 to 1.0)
    private var animationPhase: Double = 0.0
    /// Whether animation is currently running
    private var isAnimating = false

    private override init() {
        super.init()
    }

    func setup(appState: AppState) {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Set initial icon
        updateIcon(for: appState, animated: false)

        // Setup button action
        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover with SwiftUI content
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 400)
        popover?.behavior = .transient
        popover?.animates = true
        popover?.contentViewController = NSHostingController(
            rootView: MenuBarView().environment(appState)
        )

        // Observe state changes using a periodic check
        // (Observable macro doesn't work well with Combine directly)
        startObservingState(appState: appState)
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
                // Complete cycle every ~1.2 seconds (smoother, calmer pulse)
                self.animationPhase += 0.08
                if self.animationPhase > .pi * 2 {
                    self.animationPhase = 0
                }

                self.updateIcon(for: appState, animated: true)

                // ~30fps animation (33ms between frames)
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
        image.isTemplate = false // Disable template to allow custom colors

        // Determine the color based on state
        let color: NSColor
        if appState.isRecording {
            // Recording: Pulsing red
            let pulseAlpha = animated ? 0.5 + 0.5 * sin(animationPhase) : 1.0
            color = NSColor.systemRed.withAlphaComponent(CGFloat(pulseAlpha))
        } else if appState.transcriptionState == .processing {
            // Processing: Steady lighter red
            color = NSColor.systemRed.withAlphaComponent(0.6)
        } else if appState.ttsState == .speaking {
            // Speaking: Pulsing blue
            let pulseAlpha = animated ? 0.5 + 0.5 * sin(animationPhase) : 1.0
            color = NSColor.systemBlue.withAlphaComponent(CGFloat(pulseAlpha))
        } else if appState.ttsState == .loading {
            // Loading TTS: Steady lighter blue
            color = NSColor.systemBlue.withAlphaComponent(0.6)
        } else {
            // Default: use template mode for system appearance
            image.isTemplate = true
            button.image = image
            return
        }

        // Create tinted image
        let tintedImage = tintImage(image, with: color)
        button.image = tintedImage
    }

    private func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        let size = image.size
        let newImage = NSImage(size: size)

        newImage.lockFocus()

        // Draw the original image
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver,
                   fraction: 1.0)

        // Apply color tint
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)

        newImage.unlockFocus()

        newImage.isTemplate = false
        return newImage
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Make the popover's window key to receive keyboard events
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    deinit {
        observationTask?.cancel()
        animationTask?.cancel()
    }
}
