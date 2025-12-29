#!/usr/bin/env swift
//
// generate-icons.swift
// Generate placeholder icons for Ora from SF Symbols
//
// Usage: swift scripts/generate-icons.swift
//
// This script generates:
// - App icon (all required sizes) from a base design
// - Menu bar icons (all states) from SF Symbols as placeholders
//
// Note: For production, replace with custom-designed assets.
//

import AppKit
import Foundation

// MARK: - Configuration

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetsPath = projectRoot.appendingPathComponent("Ora/Assets.xcassets")

// Menu bar icon states with their SF Symbol names
let menuBarStates: [(name: String, symbol: String)] = [
    ("menubar-idle", "circle"),
    ("menubar-listening", "circle.fill"),
    ("menubar-thinking", "circle.dotted"),
    ("menubar-speaking", "speaker.wave.2.fill"),
    ("menubar-error", "exclamationmark.triangle"),
    ("menubar-setup", "arrow.down.circle")
]

// App icon sizes (pixels)
let appIconSizes: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

// MARK: - Icon Generation

func generateMenuBarIcon(symbol: String, size: CGSize, color: NSColor = .black) -> NSImage? {
    // Use smaller symbol size for menu bar (60% of canvas with padding)
    let symbolPointSize = size.height * 0.6
    let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
    guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        print("  Failed to load SF Symbol: \(symbol)")
        return nil
    }

    // Create a new image with the specified size
    let image = NSImage(size: size)
    image.lockFocus()

    // Draw the symbol centered
    let symbolSize = symbolImage.size
    let x = (size.width - symbolSize.width) / 2
    let y = (size.height - symbolSize.height) / 2
    let rect = NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height)

    // Draw with tint color
    color.set()
    symbolImage.draw(in: rect)

    image.unlockFocus()
    image.isTemplate = true
    return image
}

func generateAppIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Background gradient (blue-ish)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.259, green: 0.478, blue: 0.898, alpha: 1.0),
        NSColor(red: 0.149, green: 0.298, blue: 0.698, alpha: 1.0)
    ])

    // Draw rounded rect background
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22 // macOS icon corner radius ratio
    let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
    gradient?.draw(in: path, angle: -45)

    // Draw a stylized "O" with waveform
    let center = CGFloat(size) / 2
    let outerRadius = CGFloat(size) * 0.35
    let lineWidth = CGFloat(size) * 0.06

    NSColor.white.setStroke()

    // Outer circle
    let circlePath = NSBezierPath(ovalIn: NSRect(
        x: center - outerRadius,
        y: center - outerRadius,
        width: outerRadius * 2,
        height: outerRadius * 2
    ))
    circlePath.lineWidth = lineWidth
    circlePath.stroke()

    // Waveform bars inside the circle
    let barWidth = CGFloat(size) * 0.04
    let barSpacing = CGFloat(size) * 0.06
    let barHeights: [CGFloat] = [0.15, 0.25, 0.35, 0.25, 0.15]

    NSColor.white.setFill()
    for (index, height) in barHeights.enumerated() {
        let x = center - (CGFloat(barHeights.count) / 2 - CGFloat(index)) * barSpacing - barWidth / 2
        let barHeight = CGFloat(size) * height
        let y = center - barHeight / 2
        let bar = NSRect(x: x, y: y, width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    // Create bitmap rep with explicit pixel dimensions
    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap"])
    }
    
    // Set DPI to 72 for 1x images (standard)
    bitmapRep.size = NSSize(width: pixelSize, height: pixelSize)
    
    // Draw the image into the bitmap
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    
    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"])
    }
    try pngData.write(to: url)
}

// MARK: - Main

print("Generating Ora icons...")
print("Assets path: \(assetsPath.path)")

// Generate menu bar icons
print("\nGenerating menu bar icons:")
for state in menuBarStates {
    let imagesetPath = assetsPath.appendingPathComponent("MenuBarIcons/\(state.name).imageset")

    // 1x (18x18 px - standard menu bar icon size per Apple HIG)
    if let image1x = generateMenuBarIcon(symbol: state.symbol, size: NSSize(width: 18, height: 18)) {
        let path1x = imagesetPath.appendingPathComponent("\(state.name).png")
        do {
            try savePNG(image1x, to: path1x, pixelSize: 18)
            print("  Created: \(state.name).png (18x18 px)")
        } catch {
            print("  Error saving \(state.name).png: \(error)")
        }
    }

    // 2x (36x36 px)
    if let image2x = generateMenuBarIcon(symbol: state.symbol, size: NSSize(width: 36, height: 36)) {
        let path2x = imagesetPath.appendingPathComponent("\(state.name)@2x.png")
        do {
            try savePNG(image2x, to: path2x, pixelSize: 36)
            print("  Created: \(state.name)@2x.png (36x36 px)")
        } catch {
            print("  Error saving \(state.name)@2x.png: \(error)")
        }
    }
}

// Generate app icons
print("\nGenerating app icons:")
let appIconPath = assetsPath.appendingPathComponent("AppIcon.appiconset")
for iconSize in appIconSizes {
    let image = generateAppIcon(size: iconSize.size)
    let path = appIconPath.appendingPathComponent("\(iconSize.name).png")
    do {
        try savePNG(image, to: path, pixelSize: iconSize.size)
        print("  Created: \(iconSize.name).png (\(iconSize.size)x\(iconSize.size) px)")
    } catch {
        print("  Error saving \(iconSize.name).png: \(error)")
    }
}

print("\nDone! Icons generated successfully.")
print("\nNote: These are placeholder icons using SF Symbols and basic shapes.")
print("Replace with custom-designed assets for production.")
