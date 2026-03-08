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
    static let maxWidth = 2048
    static let maxHeight = 768

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

        let sourceTypeIdentifier = CGImageSourceGetType(imageSource) as String?
        let sourceType = sourceTypeIdentifier.flatMap(UTType.init)
        let sourceMIMEType = sourceType?.preferredMIMEType ?? attachment.mimeType

        if resizeMode == .original || Self.isWithinBounds(width: pixelWidth, height: pixelHeight) {
            if Self.canPreserveOriginalBytes(mimeType: sourceMIMEType) {
                return Self.makeDataURL(mimeType: sourceMIMEType, data: imageData)
            }
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw CodexImageEncodingError.invalidImage
        }

        let targetSize = Self.targetSize(forWidth: pixelWidth, height: pixelHeight, resizeMode: resizeMode)
        let renderedImage = try Self.render(image: cgImage, targetSize: targetSize)
        let targetType = Self.outputType(forSourceMIMEType: sourceMIMEType)
        let encoded = try Self.encode(image: renderedImage, targetType: targetType)
        return Self.makeDataURL(mimeType: encoded.mimeType, data: encoded.data)
    }

    private static func isWithinBounds(width: Int, height: Int) -> Bool {
        return width <= Self.maxWidth && height <= Self.maxHeight
    }

    private static func canPreserveOriginalBytes(mimeType: String) -> Bool {
        switch mimeType.lowercased() {
        case "image/png", "image/jpeg", "image/webp":
            return true
        default:
            return false
        }
    }

    private static func targetSize(forWidth width: Int, height: Int, resizeMode: CodexImageResizeMode) -> CGSize {
        if resizeMode == .original || Self.isWithinBounds(width: width, height: height) {
            return CGSize(width: width, height: height)
        }

        let widthScale = CGFloat(Self.maxWidth) / CGFloat(width)
        let heightScale = CGFloat(Self.maxHeight) / CGFloat(height)
        let scale = min(widthScale, heightScale)

        return CGSize(
            width: max(Int((CGFloat(width) * scale).rounded(.toNearestOrAwayFromZero)), 1),
            height: max(Int((CGFloat(height) * scale).rounded(.toNearestOrAwayFromZero)), 1)
        )
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
