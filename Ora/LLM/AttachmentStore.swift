//
//  AttachmentStore.swift
//  Ora
//
//  Actor-backed storage for staged image attachments.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

enum ImageAttachmentSource: String, Sendable, Codable {
    case clipboard
    case fileImport
    case screenshot
}

struct StagedImageAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: ImageAttachmentSource
    let createdAt: Date
    let originalFilename: String?
    let stagedFilePath: String
    let thumbnailFilePath: String?
    let mimeType: String
    let byteCount: Int
    let pixelWidth: Int?
    let pixelHeight: Int?

    var stagedFileURL: URL {
        URL(fileURLWithPath: self.stagedFilePath)
    }

    var thumbnailFileURL: URL? {
        guard let thumbnailFilePath = self.thumbnailFilePath else {
            return nil
        }
        return URL(fileURLWithPath: thumbnailFilePath)
    }

    var llmReference: LLMImageAttachmentReference {
        LLMImageAttachmentReference(
            attachmentID: self.id,
            stagedFilePath: self.stagedFilePath,
            mimeType: self.mimeType,
            byteCount: self.byteCount,
            pixelWidth: self.pixelWidth,
            pixelHeight: self.pixelHeight
        )
    }
}

protocol AttachmentStoring: Sendable {
    func stageImageData(
        _ data: Data,
        source: ImageAttachmentSource,
        originalFilename: String?
    ) async throws -> StagedImageAttachment
    func stageImageFile(at sourceURL: URL) async throws -> StagedImageAttachment
    func removeAttachment(id: UUID) async
    func removeAttachments(ids: [UUID]) async
    func removeAllTrackedAttachments() async
}

enum AttachmentStoreError: LocalizedError {
    case invalidImageData
    case fileReadFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "The selected data is not a valid image."
        case .fileReadFailed:
            return "Ora could not read that image file."
        case .writeFailed:
            return "Ora could not stage the image attachment on disk."
        }
    }
}

actor AttachmentStore: AttachmentStoring {

    // MARK: - Singleton

    static let shared = AttachmentStore()

    // MARK: - Constants

    private static let stagedDirectoryName = "Attachments/Staged"
    private static let thumbnailsDirectoryName = "Attachments/Thumbnails"
    private static let staleFileMaxAge: TimeInterval = 60 * 60 * 24
    private static let thumbnailMaxDimensionPixels = 280

    // MARK: - Properties

    private let logger = Logger.ora(category: "AttachmentStore")
    private let fileManager: FileManager
    private let rootDirectoryURL: URL
    private let stagedDirectoryURL: URL
    private let thumbnailsDirectoryURL: URL

    private var trackedAttachments: [UUID: StagedImageAttachment] = [:]

    // MARK: - Initialization

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectoryURL = rootDirectoryURL ?? ModelPaths.oraRoot
        self.stagedDirectoryURL = self.rootDirectoryURL.appendingPathComponent(Self.stagedDirectoryName, isDirectory: true)
        self.thumbnailsDirectoryURL = self.rootDirectoryURL.appendingPathComponent(Self.thumbnailsDirectoryName, isDirectory: true)
    }

    // MARK: - Public API

    func stageImageData(
        _ data: Data,
        source: ImageAttachmentSource,
        originalFilename: String? = nil
    ) async throws -> StagedImageAttachment {
        try self.ensureDirectoriesExist()
        try self.cleanupStaleFiles()

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AttachmentStoreError.invalidImageData
        }

        let id = UUID()
        let typeIdentifier = CGImageSourceGetType(imageSource) as String?
        let inferredType = typeIdentifier.flatMap { UTType($0) }
        let mimeType = inferredType?.preferredMIMEType ?? "image/png"
        let fileExtension = inferredType?.preferredFilenameExtension ?? "png"
        let stagedURL = self.stagedDirectoryURL.appendingPathComponent("\(id.uuidString).\(fileExtension)")

        do {
            try data.write(to: stagedURL, options: [.atomic])
        } catch {
            self.logger.error("Failed to write staged attachment: \(error.localizedDescription)")
            throw AttachmentStoreError.writeFailed
        }

        let imageProperties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int
        let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int

        let thumbnailURL = self.makeThumbnail(
            for: imageSource,
            attachmentID: id
        )

        let attachment = StagedImageAttachment(
            id: id,
            source: source,
            createdAt: Date(),
            originalFilename: originalFilename,
            stagedFilePath: stagedURL.path,
            thumbnailFilePath: thumbnailURL?.path,
            mimeType: mimeType,
            byteCount: data.count,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )

        self.trackedAttachments[id] = attachment
        self.logger.info("Staged image attachment \(id.uuidString)")
        return attachment
    }

    func stageImageFile(at sourceURL: URL) async throws -> StagedImageAttachment {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            self.logger.error("Failed reading image file: \(error.localizedDescription)")
            throw AttachmentStoreError.fileReadFailed
        }

        return try await self.stageImageData(
            data,
            source: .fileImport,
            originalFilename: sourceURL.lastPathComponent
        )
    }

    func removeAttachment(id: UUID) async {
        guard let attachment = self.trackedAttachments.removeValue(forKey: id) else {
            return
        }

        try? self.fileManager.removeItem(at: attachment.stagedFileURL)
        if let thumbnailURL = attachment.thumbnailFileURL {
            try? self.fileManager.removeItem(at: thumbnailURL)
        }
    }

    func removeAttachments(ids: [UUID]) async {
        for id in ids {
            await self.removeAttachment(id: id)
        }
    }

    func removeAllTrackedAttachments() async {
        let ids = Array(self.trackedAttachments.keys)
        await self.removeAttachments(ids: ids)
    }

    // MARK: - Private

    private func ensureDirectoriesExist() throws {
        do {
            try self.fileManager.createDirectory(at: self.stagedDirectoryURL, withIntermediateDirectories: true)
            try self.fileManager.createDirectory(at: self.thumbnailsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            self.logger.error("Attachment directory creation failed: \(error.localizedDescription)")
            throw AttachmentStoreError.writeFailed
        }
    }

    private func makeThumbnail(for imageSource: CGImageSource, attachmentID: UUID) -> URL? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaxDimensionPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let thumbnailURL = self.thumbnailsDirectoryURL.appendingPathComponent("\(attachmentID.uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            thumbnailURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return thumbnailURL
    }

    private func cleanupStaleFiles() throws {
        let cutoff = Date().addingTimeInterval(-Self.staleFileMaxAge)

        try self.removeStaleFiles(in: self.stagedDirectoryURL, cutoff: cutoff)
        try self.removeStaleFiles(in: self.thumbnailsDirectoryURL, cutoff: cutoff)
    }

    private func removeStaleFiles(in directory: URL, cutoff: Date) throws {
        guard let enumerator = self.fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modifiedDate = values?.contentModificationDate else {
                continue
            }

            if modifiedDate < cutoff {
                try? self.fileManager.removeItem(at: fileURL)
            }
        }
    }
}
