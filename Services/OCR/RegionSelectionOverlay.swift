import Foundation
import AppKit

/// A full-screen overlay window for selecting a region of the screen
/// Similar to macOS screenshot selection (Cmd+Shift+4)
class RegionSelectionOverlay: NSWindow {

    // MARK: - Callbacks

    /// Called when user completes selection with a valid region
    var onSelectionComplete: ((CGRect) -> Void)?

    /// Called when user cancels selection (ESC or click without drag)
    var onCancel: (() -> Void)?

    // MARK: - Private Properties

    private var selectionView: SelectionView!

    // MARK: - Initialization

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setupWindow()
    }

    convenience init() {
        // Get the combined frame of all screens
        let allScreensFrame = NSScreen.screens.reduce(CGRect.zero) { result, screen in
            result.union(screen.frame)
        }

        self.init(
            contentRect: allScreensFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }

    private func setupWindow() {
        // Configure window properties
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Above most windows
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Create selection view
        selectionView = SelectionView(frame: self.frame)
        selectionView.onSelectionComplete = { [weak self] rect in
            self?.handleSelectionComplete(rect)
        }
        selectionView.onCancel = { [weak self] in
            self?.handleCancel()
        }

        self.contentView = selectionView
    }

    // MARK: - Public Methods

    /// Show the overlay on all screens and begin selection mode
    func beginSelection() {
        // Activate the app to ensure we receive mouse events immediately
        NSApp.activate(ignoringOtherApps: true)

        // Get combined frame of all screens
        let allScreensFrame = NSScreen.screens.reduce(CGRect.zero) { result, screen in
            result.union(screen.frame)
        }

        // Set window to cover all screens
        self.setFrame(allScreensFrame, display: true)

        // Update selection view frame to match window
        selectionView.frame = NSRect(origin: .zero, size: allScreensFrame.size)

        // Show main window
        self.makeKeyAndOrderFront(nil)

        // Set crosshair cursor
        NSCursor.crosshair.push()

        // Make this window key and first responder to receive events immediately
        self.makeKey()
        self.makeFirstResponder(selectionView)
        dprint("RegionSelectionOverlay: Selection started, frame: \(allScreensFrame)")

    }

    /// Close the overlay and clean up
    func endSelection() {
        NSCursor.pop()

        // Close main window
        self.orderOut(nil)
        dprint("RegionSelectionOverlay: Selection ended")

    }

    // MARK: - Private Methods

    private func handleSelectionComplete(_ rect: CGRect) {
        endSelection()
        onSelectionComplete?(rect)
    }

    private func handleCancel() {
        endSelection()
        onCancel?()
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC key
            handleCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - SelectionView

/// Custom view that handles mouse events for region selection
private class SelectionView: NSView {

    var onSelectionComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var selectionStart: NSPoint?
    private var selectionEnd: NSPoint?
    private var isSelecting = false

    // Selection rectangle colors
    private let selectionFillColor = NSColor.systemBlue.withAlphaComponent(0.2)
    private let selectionStrokeColor = NSColor.white
    private let overlayColor = NSColor.black.withAlphaComponent(0.3)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw semi-transparent overlay
        overlayColor.setFill()
        bounds.fill()

        // Draw selection rectangle if selecting
        if isSelecting, let start = selectionStart, let end = selectionEnd {
            let selectionRect = rectFromPoints(start, end)

            // Clear the selection area (make it transparent)
            NSColor.clear.setFill()
            selectionRect.fill(using: .copy)

            // Draw selection fill
            selectionFillColor.setFill()
            selectionRect.fill()

            // Draw selection border (dashed white line)
            let borderPath = NSBezierPath(rect: selectionRect)
            borderPath.lineWidth = 1.5
            selectionStrokeColor.setStroke()
            borderPath.setLineDash([5, 3], count: 2, phase: 0)
            borderPath.stroke()

            // Draw corner handles
            drawCornerHandles(for: selectionRect)

            // Draw size label
            drawSizeLabel(for: selectionRect)
        } else {
            // Draw instruction text when not selecting
            drawInstructions()
        }
    }

    private func drawInstructions() {
        // Main instruction text
        let mainText = "Drag to select OCR region"
        let subText = "Press ESC to cancel"

        // Main text attributes
        let mainAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        // Sub text attributes
        let subAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]

        let mainAttrString = NSAttributedString(string: mainText, attributes: mainAttributes)
        let subAttrString = NSAttributedString(string: subText, attributes: subAttributes)

        let mainSize = mainAttrString.size()
        let subSize = subAttrString.size()

        // Calculate positions (center of screen)
        let totalHeight = mainSize.height + 8 + subSize.height
        let centerY = bounds.midY

        // Draw background pill for better visibility
        let pillPadding: CGFloat = 24
        let pillWidth = max(mainSize.width, subSize.width) + pillPadding * 2
        let pillHeight = totalHeight + pillPadding * 2
        let pillRect = NSRect(
            x: bounds.midX - pillWidth / 2,
            y: centerY - pillHeight / 2,
            width: pillWidth,
            height: pillHeight
        )

        // Draw pill background
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 16, yRadius: 16)
        NSColor.black.withAlphaComponent(0.6).setFill()
        pillPath.fill()

        // Draw border
        NSColor.white.withAlphaComponent(0.3).setStroke()
        pillPath.lineWidth = 2
        pillPath.stroke()

        // Draw main text
        let mainOrigin = NSPoint(
            x: bounds.midX - mainSize.width / 2,
            y: centerY + 4
        )
        mainAttrString.draw(at: mainOrigin)

        // Draw sub text
        let subOrigin = NSPoint(
            x: bounds.midX - subSize.width / 2,
            y: centerY - subSize.height - 4
        )
        subAttrString.draw(at: subOrigin)

        // Draw crosshair icon at the top
        drawCrosshairIcon(at: NSPoint(x: bounds.midX, y: centerY + mainSize.height + 24))
    }

    private func drawCrosshairIcon(at center: NSPoint) {
        let iconSize: CGFloat = 32
        let lineLength: CGFloat = 10

        NSColor.white.setStroke()

        // Horizontal line
        let hPath = NSBezierPath()
        hPath.move(to: NSPoint(x: center.x - iconSize / 2, y: center.y))
        hPath.line(to: NSPoint(x: center.x - lineLength, y: center.y))
        hPath.move(to: NSPoint(x: center.x + lineLength, y: center.y))
        hPath.line(to: NSPoint(x: center.x + iconSize / 2, y: center.y))
        hPath.lineWidth = 2
        hPath.stroke()

        // Vertical line
        let vPath = NSBezierPath()
        vPath.move(to: NSPoint(x: center.x, y: center.y - iconSize / 2))
        vPath.line(to: NSPoint(x: center.x, y: center.y - lineLength))
        vPath.move(to: NSPoint(x: center.x, y: center.y + lineLength))
        vPath.line(to: NSPoint(x: center.x, y: center.y + iconSize / 2))
        vPath.lineWidth = 2
        vPath.stroke()

        // Circle
        let circleRect = NSRect(
            x: center.x - iconSize / 2,
            y: center.y - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        let circlePath = NSBezierPath(ovalIn: circleRect)
        circlePath.lineWidth = 2
        circlePath.stroke()
    }

    private func drawCornerHandles(for rect: NSRect) {
        let handleSize: CGFloat = 6
        let handleColor = NSColor.white

        let corners = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY)
        ]

        handleColor.setFill()
        for corner in corners {
            let handleRect = NSRect(
                x: corner.x - handleSize / 2,
                y: corner.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSBezierPath(ovalIn: handleRect).fill()
        }
    }

    private func drawSizeLabel(for rect: NSRect) {
        let width = Int(rect.width)
        let height = Int(rect.height)
        let sizeText = "\(width) × \(height)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]

        let attributedString = NSAttributedString(string: " \(sizeText) ", attributes: attributes)
        let textSize = attributedString.size()

        // Position label below selection if possible, otherwise above
        var labelOrigin = NSPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.minY - textSize.height - 8
        )

        // Adjust if label would be off-screen
        if labelOrigin.y < 0 {
            labelOrigin.y = rect.maxY + 8
        }
        if labelOrigin.x < 0 {
            labelOrigin.x = 4
        }
        if labelOrigin.x + textSize.width > bounds.maxX {
            labelOrigin.x = bounds.maxX - textSize.width - 4
        }

        attributedString.draw(at: labelOrigin)
    }

    private func rectFromPoints(_ point1: NSPoint, _ point2: NSPoint) -> NSRect {
        let minX = min(point1.x, point2.x)
        let minY = min(point1.y, point2.y)
        let maxX = max(point1.x, point2.x)
        let maxY = max(point1.y, point2.y)
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        selectionStart = convert(event.locationInWindow, from: nil)
        selectionEnd = selectionStart
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        selectionEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelecting, let start = selectionStart, let end = selectionEnd else {
            onCancel?()
            return
        }

        isSelecting = false
        let selectionRect = rectFromPoints(start, end)

        // Check if selection is large enough (minimum 10x10 pixels)
        if selectionRect.width >= 10 && selectionRect.height >= 10 {
            // Convert to screen coordinates
            let screenRect = window?.convertToScreen(selectionRect) ?? selectionRect
            onSelectionComplete?(screenRect)
        } else {
            // Selection too small, treat as cancel
            onCancel?()
        }

        // Reset state
        selectionStart = nil
        selectionEnd = nil
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
}
