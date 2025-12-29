#!/usr/bin/env swift
//
// resize-app-icon.swift
// Resize the source app icon to all required sizes
//
// Usage: swift scripts/resize-app-icon.swift [source-icon-path]
//        Default source: ora-icon.png in project root
//

import AppKit
import Foundation

// MARK: - Configuration

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let defaultSourcePath = projectRoot.appendingPathComponent("ora-icon.png")
let assetsPath = projectRoot.appendingPathComponent("Ora/Assets.xcassets")
let appIconPath = assetsPath.appendingPathComponent("AppIcon.appiconset")

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

// MARK: - Image Resizing

func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
    let newImage = NSImage(size: size)
    newImage.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy,
               fraction: 1.0)

    newImage.unlockFocus()
    return newImage
}

func savePNG(_ image: NSImage, to url: URL, size: Int) throws {
    // Create a bitmap representation at the exact pixel size
    guard let bitmapRep = NSBitmapImageRep(
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
    ) else {
        throw NSError(domain: "IconResizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap"])
    }

    bitmapRep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
    NSGraphicsContext.current?.imageInterpolation = .high

    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy,
               fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconResizer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"])
    }

    try pngData.write(to: url)
}

// MARK: - Main

let args = CommandLine.arguments
let sourcePath: URL
if args.count > 1 {
    sourcePath = URL(fileURLWithPath: args[1])
} else {
    sourcePath = defaultSourcePath
}

print("Resizing app icon...")
print("Source: \(sourcePath.path)")
print("Destination: \(appIconPath.path)")

guard let sourceImage = NSImage(contentsOf: sourcePath) else {
    print("Error: Could not load source image from \(sourcePath.path)")
    exit(1)
}

print("Source image size: \(Int(sourceImage.size.width))x\(Int(sourceImage.size.height))")
print("")

for iconSize in appIconSizes {
    let outputPath = appIconPath.appendingPathComponent("\(iconSize.name).png")
    do {
        try savePNG(sourceImage, to: outputPath, size: iconSize.size)
        print("Created: \(iconSize.name).png (\(iconSize.size)x\(iconSize.size) px)")
    } catch {
        print("Error creating \(iconSize.name).png: \(error)")
    }
}

print("")
print("Done! App icon resized successfully.")
