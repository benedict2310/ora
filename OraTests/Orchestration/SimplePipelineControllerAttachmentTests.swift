import XCTest
@testable import Ora

@MainActor
final class SimplePipelineControllerAttachmentTests: XCTestCase {

    func test_consumePendingImageAttachmentsForTurn_clearsComposeState() {
        let overlay = MockOverlayPresenter()
        let store = MockAttachmentStore()
        let screenshotService = MockScreenshotCaptureService()
        let controller = SimplePipelineController.makeTestInstance(
            overlayPresenter: overlay,
            attachmentStore: store,
            screenshotCaptureService: screenshotService
        )

        let attachment = Self.sampleAttachment(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        controller.setPendingImageAttachmentsForTesting([attachment])

        let consumed = controller.consumePendingImageAttachmentsForTurn()

        XCTAssertEqual(consumed.map(\.id), [attachment.id])
        XCTAssertTrue(controller.pendingImageAttachments.isEmpty)
        XCTAssertTrue(overlay.model.pendingImageAttachments.isEmpty)
    }

    func test_clearPendingImageAttachments_removesStagedFilesAndClearsOverlay() async {
        let overlay = MockOverlayPresenter()
        let store = MockAttachmentStore()
        let screenshotService = MockScreenshotCaptureService()
        let controller = SimplePipelineController.makeTestInstance(
            overlayPresenter: overlay,
            attachmentStore: store,
            screenshotCaptureService: screenshotService
        )

        let first = Self.sampleAttachment(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let second = Self.sampleAttachment(id: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!)
        controller.setPendingImageAttachmentsForTesting([first, second])

        controller.clearPendingImageAttachments()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(controller.pendingImageAttachments.isEmpty)
        XCTAssertTrue(overlay.model.pendingImageAttachments.isEmpty)

        let removedIDs = await store.removedAttachmentIDs
        XCTAssertEqual(Set(removedIDs), Set([first.id, second.id]))
    }

    func test_cancel_clearsPendingAndSessionAttachmentState() async {
        let overlay = MockOverlayPresenter()
        let store = MockAttachmentStore()
        let screenshotService = MockScreenshotCaptureService()
        let controller = SimplePipelineController.makeTestInstance(
            overlayPresenter: overlay,
            attachmentStore: store,
            screenshotCaptureService: screenshotService
        )

        let pending = Self.sampleAttachment(id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!)
        let sessionID = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!

        controller.setPendingImageAttachmentsForTesting([pending])
        controller.sessionImageAttachmentIDs = [sessionID]

        controller.cancel()
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.pendingImageAttachments.isEmpty)
        XCTAssertTrue(controller.sessionImageAttachmentIDs.isEmpty)

        let removedIDs = await store.removedAttachmentIDs
        XCTAssertEqual(Set(removedIDs), Set([pending.id, sessionID]))
    }

    func test_openScreenRecordingSettings_delegatesToScreenshotService() async {
        let overlay = MockOverlayPresenter()
        let store = MockAttachmentStore()
        let screenshotService = MockScreenshotCaptureService()
        let controller = SimplePipelineController.makeTestInstance(
            overlayPresenter: overlay,
            attachmentStore: store,
            screenshotCaptureService: screenshotService
        )

        controller.openScreenRecordingSettings()
        try? await Task.sleep(for: .milliseconds(650))

        XCTAssertEqual(screenshotService.openSettingsCallCount, 1)
    }

    private static func sampleAttachment(id: UUID) -> StagedImageAttachment {
        return StagedImageAttachment(
            id: id,
            source: .clipboard,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalFilename: nil,
            stagedFilePath: "/tmp/\(id.uuidString).png",
            thumbnailFilePath: nil,
            mimeType: "image/png",
            byteCount: 4096,
            pixelWidth: 1024,
            pixelHeight: 768
        )
    }
}
