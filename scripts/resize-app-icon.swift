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

func bitmapRep(for image: NSImage) -> NSBitmapImageRep? {
    if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
        return rep
    }
    guard let tiff = image.tiffRepresentation else {
        return nil
    }
    return NSBitmapImageRep(data: tiff)
}

func alphaBoundingBox(for rep: NSBitmapImageRep) -> CGRect? {
    guard rep.samplesPerPixel >= 4,
          let data = rep.bitmapData else {
        return nil
    }

    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    let bytesPerRow = rep.bytesPerRow
    let samplesPerPixel = rep.samplesPerPixel
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1

    for y in 0..<height {
        let row = data + y * bytesPerRow
        for x in 0..<width {
            let pixel = row + x * samplesPerPixel
            if pixel[3] > 2 { // ~1% alpha threshold
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }
    }

    guard maxX >= 0, maxY >= 0 else {
        return nil
    }

    return CGRect(
        x: CGFloat(minX),
        y: CGFloat(minY),
        width: CGFloat(maxX - minX + 1),
        height: CGFloat(maxY - minY + 1)
    )
}

func centeredImage(_ image: NSImage) -> NSImage {
    guard let rep = bitmapRep(for: image),
          let bbox = alphaBoundingBox(for: rep),
          let srcData = rep.bitmapData else {
        return image
    }

    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    let pixelSize = CGSize(width: width, height: height)
    let targetCenter = CGPoint(x: pixelSize.width / 2.0, y: pixelSize.height / 2.0)
    let bboxCenter = CGPoint(x: bbox.midX, y: bbox.midY)
    let dx = Int(round(targetCenter.x - bboxCenter.x))
    let dy = Int(round(targetCenter.y - bboxCenter.y))

    if dx == 0 && dy == 0 {
        return image
    }

    guard let newRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: rep.bitsPerSample,
        samplesPerPixel: rep.samplesPerPixel,
        hasAlpha: rep.hasAlpha,
        isPlanar: false,
        colorSpaceName: rep.colorSpaceName,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let dstData = newRep.bitmapData else {
        return image
    }

    let srcBytesPerRow = rep.bytesPerRow
    let dstBytesPerRow = newRep.bytesPerRow
    let samplesPerPixel = rep.samplesPerPixel
    memset(dstData, 0, dstBytesPerRow * height)

    for y in 0..<height {
        let newY = y + dy
        if newY < 0 || newY >= height { continue }
        let srcRow = srcData + y * srcBytesPerRow
        let dstRow = dstData + newY * dstBytesPerRow
        if dx == 0 {
            memcpy(dstRow, srcRow, width * samplesPerPixel)
        } else {
            for x in 0..<width {
                let newX = x + dx
                if newX < 0 || newX >= width { continue }
                let srcPixel = srcRow + x * samplesPerPixel
                let dstPixel = dstRow + newX * samplesPerPixel
                for channel in 0..<samplesPerPixel {
                    dstPixel[channel] = srcPixel[channel]
                }
            }
        }
    }

    let newImage = NSImage(size: pixelSize)
    newImage.addRepresentation(newRep)
    return newImage
}

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

func savePNG(_ image: NSImage, to url: URL, size: Int, is2x: Bool) throws {
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

    // Set the point size (for @2x, point size is half the pixel size)
    let pointSize = is2x ? size / 2 : size
    bitmapRep.size = NSSize(width: pointSize, height: pointSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
    NSGraphicsContext.current?.imageInterpolation = .high

    image.draw(in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
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

let centeredSourceImage = centeredImage(sourceImage)

print("Source image size: \(Int(sourceImage.size.width))x\(Int(sourceImage.size.height))")
if centeredSourceImage !== sourceImage {
    print("Centering source image based on alpha bounds.")
}
print("")

for iconSize in appIconSizes {
    let outputPath = appIconPath.appendingPathComponent("\(iconSize.name).png")
    let is2x = iconSize.name.contains("@2x")
    do {
        try savePNG(centeredSourceImage, to: outputPath, size: iconSize.size, is2x: is2x)
        print("Created: \(iconSize.name).png (\(iconSize.size)x\(iconSize.size) px)")
    } catch {
        print("Error creating \(iconSize.name).png: \(error)")
    }
}

print("")
print("Done! App icon resized successfully.")
