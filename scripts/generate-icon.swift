#!/usr/bin/env swift

import AppKit

// Configuration
let symbolName = "waveform.badge.microphone"
// Gradient colors: darker blue at top, lighter blue at bottom
let gradientTopColor = NSColor(red: 0/255, green: 90/255, blue: 220/255, alpha: 1.0)    // Darker blue
let gradientBottomColor = NSColor(red: 50/255, green: 160/255, blue: 255/255, alpha: 1.0) // Lighter blue
let symbolColor = NSColor.white
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = "Resources/Assets.xcassets/AppIcon.appiconset"

// Create output directory if needed
let fileManager = FileManager.default
let currentDir = fileManager.currentDirectoryPath
let outputPath = "\(currentDir)/\(outputDir)"

for size in sizes {
    let imageSize = NSSize(width: size, height: size)

    // Create bitmap representation directly to avoid scaling issues
    let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)

    // Draw rounded rectangle with gradient background
    let rect = NSRect(origin: .zero, size: imageSize)
    let cornerRadius = CGFloat(size) / 5.0
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Create gradient
    let gradient = NSGradient(starting: gradientTopColor, ending: gradientBottomColor)!
    gradient.draw(in: path, angle: -90) // Top to bottom

    // Draw SF Symbol
    let symbolPointSize = CGFloat(size) * 0.65
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
    if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        // Create tinted version
        let tintedImage = NSImage(size: symbolImage.size)
        tintedImage.lockFocus()
        symbolImage.draw(in: NSRect(origin: .zero, size: symbolImage.size))
        symbolColor.set()
        NSRect(origin: .zero, size: symbolImage.size).fill(using: .sourceAtop)
        tintedImage.unlockFocus()

        // Center the symbol
        let symbolSize = tintedImage.size
        let x = (CGFloat(size) - symbolSize.width) / 2
        let y = (CGFloat(size) - symbolSize.height) / 2
        tintedImage.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
    }

    NSGraphicsContext.restoreGraphicsState()

    // Save as PNG
    if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
        let filename = "\(outputPath)/icon_\(size)x\(size).png"
        try? pngData.write(to: URL(fileURLWithPath: filename))
        print("Created: icon_\(size)x\(size).png (\(size)x\(size) pixels)")
    }
}

print("Done! Icons generated in \(outputDir)")
