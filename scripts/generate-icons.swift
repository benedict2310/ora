#!/usr/bin/env swift
//
// generate-icons.swift
// Generate menu bar icons for Ora from SF Symbols
//
// Usage: swift scripts/generate-icons.swift
//
// This script generates menu bar icons (all states) from SF Symbols as placeholders.
// For app icons, use: swift scripts/resize-app-icon.swift
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

// NOTE: App icons are NOT generated here.
// Use `swift scripts/resize-app-icon.swift` to resize the custom ora-icon.png source.

print("\nDone! Menu bar icons generated successfully.")
print("\nNote: Menu bar icons use SF Symbols as placeholders.")
print("For app icon, run: swift scripts/resize-app-icon.swift")
