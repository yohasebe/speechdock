import AppKit
import SwiftUI
import Combine

/// Manages the menu bar status item with dynamic icon colors
@MainActor
final class StatusBarManager: NSObject {
    static let shared = StatusBarManager()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var observationTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func setup(appState: AppState) {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Set initial icon
        updateIcon(for: appState)

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
                    self.updateIcon(for: appState)
                }
            }
        }
    }

    private func getCurrentIconState(for appState: AppState) -> Int {
        if appState.isRecording { return 1 }
        if appState.transcriptionState == .processing { return 2 }
        if appState.ttsState == .speaking { return 3 }
        if appState.ttsState == .loading { return 4 }
        return 0
    }

    private func updateIcon(for appState: AppState) {
        guard let button = statusItem?.button else { return }

        // Load the template image
        guard let image = NSImage(named: "MenuBarIcon") else { return }
        image.isTemplate = false // Disable template to allow custom colors

        // Determine the color based on state
        let color: NSColor
        if appState.isRecording {
            color = .systemRed
        } else if appState.transcriptionState == .processing {
            color = NSColor.systemRed.withAlphaComponent(0.7)
        } else if appState.ttsState == .speaking {
            color = .systemBlue
        } else if appState.ttsState == .loading {
            color = NSColor.systemBlue.withAlphaComponent(0.7)
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
    }
}
