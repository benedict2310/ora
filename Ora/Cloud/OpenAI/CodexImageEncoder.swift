//
//  CodexImageEncoder.swift
//  Ora
//
//  Prepares staged image attachments for Codex Responses requests.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CodexImageEncodingError: LocalizedError {
    case fileMissing
    case fileReadFailed
    case invalidImage
    case renderingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "The attached image could not be found on disk. Please attach the image again and retry."
        case .fileReadFailed:
            return "Ora could not read that image file."
        case .invalidImage:
            return "Ora could not read that image."
        case .renderingFailed:
            return "Ora could not prepare that image for upload."
        case .encodingFailed:
            return "Ora could not encode that image for upload."
        }
    }
}

enum CodexImageResizeMode {
    case resizeToFit
    case original
}

enum CodexImageEncoder {
    static let maxLandscapeWidth = 2048
    static let maxLandscapeHeight = 768
    static let maxPortraitWidth = 768
    static let maxPortraitHeight = 2048
    static let maxSquareDimension = 2048

    static func dataURL(
        for attachment: LLMImageAttachmentReference,
        resizeMode: CodexImageResizeMode
    ) throws -> String {
        let fileURL = URL(fileURLWithPath: attachment.stagedFilePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CodexImageEncodingError.fileMissing
        }

        let imageData: Data
        do {
            imageData = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw CodexImageEncodingError.fileReadFailed
        }

        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw CodexImageEncodingError.invalidImage
        }

        let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw CodexImageEncodingError.invalidImage
        }
        let imageOrientation = Self.imageOrientation(from: properties)
        let displaySize = Self.displaySize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            orientation: imageOrientation
        )

        let sourceTypeIdentifier = CGImageSourceGetType(imageSource) as String?
        let sourceType = sourceTypeIdentifier.flatMap(UTType.init)
        let sourceMIMEType = sourceType?.preferredMIMEType ?? attachment.mimeType

        if resizeMode == .original || Self.isWithinBounds(displaySize) {
            if Self.canPreserveOriginalBytes(mimeType: sourceMIMEType) {
                return Self.makeDataURL(mimeType: sourceMIMEType, data: imageData)
            }
        }

        let targetSize = Self.targetSize(for: displaySize, resizeMode: resizeMode)
        let normalizedImage = try Self.normalizedImage(from: imageSource, targetSize: targetSize)
        let renderedImage = try Self.render(image: normalizedImage, targetSize: targetSize)
        let targetType = Self.outputType(forSourceMIMEType: sourceMIMEType)
        let encoded = try Self.encode(image: renderedImage, targetType: targetType)
        return Self.makeDataURL(mimeType: encoded.mimeType, data: encoded.data)
    }

    private static func imageOrientation(from properties: [CFString: Any]) -> CGImagePropertyOrientation {
        if let rawValue = properties[kCGImagePropertyOrientation] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: rawValue) {
            return orientation
        }
        if let rawValue = properties[kCGImagePropertyOrientation] as? Int,
           let orientation = CGImagePropertyOrientation(rawValue: UInt32(rawValue)) {
            return orientation
        }
        return .up
    }

    private static func displaySize(
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        if orientation.swapsDimensions {
            return CGSize(width: pixelHeight, height: pixelWidth)
        }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    private static func maxSize(for displaySize: CGSize) -> CGSize {
        if displaySize.width == displaySize.height {
            return CGSize(width: Self.maxSquareDimension, height: Self.maxSquareDimension)
        }
        if displaySize.width > displaySize.height {
            return CGSize(width: Self.maxLandscapeWidth, height: Self.maxLandscapeHeight)
        }
        return CGSize(width: Self.maxPortraitWidth, height: Self.maxPortraitHeight)
    }

    private static func isWithinBounds(_ displaySize: CGSize) -> Bool {
        let maxSize = Self.maxSize(for: displaySize)
        return displaySize.width <= maxSize.width && displaySize.height <= maxSize.height
    }

    private static func canPreserveOriginalBytes(mimeType: String) -> Bool {
        switch mimeType.lowercased() {
        case "image/png", "image/jpeg", "image/webp":
            return true
        default:
            return false
        }
    }

    private static func targetSize(for displaySize: CGSize, resizeMode: CodexImageResizeMode) -> CGSize {
        if resizeMode == .original || Self.isWithinBounds(displaySize) {
            return displaySize
        }

        let maxSize = Self.maxSize(for: displaySize)
        let widthScale = maxSize.width / displaySize.width
        let heightScale = maxSize.height / displaySize.height
        let scale = min(widthScale, heightScale)

        return CGSize(
            width: max(Int((displaySize.width * scale).rounded(.toNearestOrAwayFromZero)), 1),
            height: max(Int((displaySize.height * scale).rounded(.toNearestOrAwayFromZero)), 1)
        )
    }

    private static func normalizedImage(from imageSource: CGImageSource, targetSize: CGSize) throws -> CGImage {
        let maxPixelSize = max(Int(max(targetSize.width, targetSize.height).rounded(.up)), 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw CodexImageEncodingError.invalidImage
        }
        return image
    }

    private static func render(image: CGImage, targetSize: CGSize) throws -> CGImage {
        if image.width == Int(targetSize.width), image.height == Int(targetSize.height) {
            return image
        }

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CodexImageEncodingError.renderingFailed
        }

        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CodexImageEncodingError.renderingFailed
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))

        guard let renderedImage = context.makeImage() else {
            throw CodexImageEncodingError.renderingFailed
        }

        return renderedImage
    }

    private static func outputType(forSourceMIMEType mimeType: String) -> UTType {
        switch mimeType.lowercased() {
        case "image/jpeg":
            return .jpeg
        case "image/webp":
            return .webP
        default:
            return .png
        }
    }

    private static func encode(image: CGImage, targetType: UTType) throws -> (data: Data, mimeType: String) {
        func attemptEncode(_ type: UTType) -> Data? {
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            return buffer as Data
        }

        if let encoded = attemptEncode(targetType) {
            return (encoded, targetType.preferredMIMEType ?? "image/png")
        }
        if targetType != .png, let encoded = attemptEncode(.png) {
            return (encoded, "image/png")
        }
        throw CodexImageEncodingError.encodingFailed
    }

    private static func makeDataURL(mimeType: String, data: Data) -> String {
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

private extension CGImagePropertyOrientation {
    var swapsDimensions: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            return true
        default:
            return false
        }
    }
}
