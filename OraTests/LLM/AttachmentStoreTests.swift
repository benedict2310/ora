import XCTest
import AppKit
@testable import Ora

final class AttachmentStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.tempRoot = directory
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func test_stageImageData_writesStagedFileAndMetadata() async throws {
        let store = AttachmentStore(rootDirectoryURL: self.tempRoot)
        let pngData = try XCTUnwrap(Self.makePNGData(width: 32, height: 24))

        let attachment = try await store.stageImageData(
            pngData,
            source: .clipboard,
            originalFilename: "pasted.png"
        )

        XCTAssertEqual(attachment.source, .clipboard)
        XCTAssertEqual(attachment.originalFilename, "pasted.png")
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.byteCount, pngData.count)
        XCTAssertEqual(attachment.pixelWidth, 32)
        XCTAssertEqual(attachment.pixelHeight, 24)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.stagedFilePath))
    }

    func test_removeAttachment_deletesTrackedFiles() async throws {
        let store = AttachmentStore(rootDirectoryURL: self.tempRoot)
        let pngData = try XCTUnwrap(Self.makePNGData(width: 20, height: 20))

        let attachment = try await store.stageImageData(
            pngData,
            source: .screenshot,
            originalFilename: nil
        )

        await store.removeAttachment(id: attachment.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.stagedFilePath))
        if let thumbnailFilePath = attachment.thumbnailFilePath {
            XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailFilePath))
        }
    }

    private static func makePNGData(width: Int, height: Int) -> Data? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let bitmap else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current = context
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        context?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }
}
