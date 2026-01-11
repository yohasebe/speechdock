#!/usr/bin/env swift

import AppKit

// Configuration
let symbolName = "waveform.badge.microphone"
let outputDir = "Resources/Assets.xcassets/MenuBarIcon.imageset"

let fileManager = FileManager.default
let currentDir = fileManager.currentDirectoryPath
let outputPath = "\(currentDir)/\(outputDir)"

// Create directory if needed
try? fileManager.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

// Menu bar icons: 18pt for 1x, 36pt for 2x (Retina)
let sizes = [(18, ""), (36, "@2x")]

for (size, suffix) in sizes {
    let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: NSColorSpaceName.deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmapRep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmapRep)
    context?.imageInterpolation = NSImageInterpolation.high
    NSGraphicsContext.current = context

    // Draw SF Symbol with bold weight for thicker lines
    let symbolPointSize = CGFloat(size) * 0.8
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .bold)
    if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        // Draw centered, filling the space
        let targetSize = CGFloat(size)
        let x = (targetSize - symbolImage.size.width) / 2
        let y = (targetSize - symbolImage.size.height) / 2
        symbolImage.draw(in: NSRect(x: x, y: y, width: symbolImage.size.width, height: symbolImage.size.height),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()

    // Save as PNG
    if let pngData = bitmapRep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
        let filename = "\(outputPath)/menubar\(suffix).png"
        try? pngData.write(to: URL(fileURLWithPath: filename))
        print("Created: menubar\(suffix).png (\(size)x\(size) pixels)")
    }
}

// Create Contents.json with template mode for crisp system rendering
let contentsJson = """
{
  "images" : [
    {
      "filename" : "menubar.png",
      "idiom" : "mac",
      "scale" : "1x"
    },
    {
      "filename" : "menubar@2x.png",
      "idiom" : "mac",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
"""

let contentsPath = "\(outputPath)/Contents.json"
try? contentsJson.write(toFile: contentsPath, atomically: true, encoding: .utf8)
print("Created: Contents.json")

print("Done! Menu bar icons generated in \(outputDir)")
