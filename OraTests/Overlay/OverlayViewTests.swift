import XCTest
import SwiftUI
@testable import Ora

@MainActor
final class OverlayViewTests: XCTestCase {

    func test_attachmentTrayView_bodyBuilds_withPendingAttachments() {
        let tray = AttachmentTrayView(
            attachments: [Self.sampleAttachment()],
            reduceTransparency: true,
            onRemove: { _ in },
            onClearAll: {}
        )

        _ = tray.body
    }

    func test_attachmentTrayView_removeAndClearCallbacks_areCallable() {
        let attachment = Self.sampleAttachment()
        var removedID: UUID?
        var clearCalled = false

        let tray = AttachmentTrayView(
            attachments: [attachment],
            reduceTransparency: false,
            onRemove: { id in
                removedID = id
            },
            onClearAll: {
                clearCalled = true
            }
        )

        tray.onRemove(attachment.id)
        tray.onClearAll()

        XCTAssertEqual(removedID, attachment.id)
        XCTAssertTrue(clearCalled)
    }

    func test_overlayViewModel_reset_clearsPendingAttachmentsAndNotice() {
        let viewModel = OverlayViewModel()
        viewModel.pendingImageAttachments = [Self.sampleAttachment()]
        viewModel.attachmentNotice = OverlayAttachmentNotice(message: "Test")

        viewModel.reset()

        XCTAssertTrue(viewModel.pendingImageAttachments.isEmpty)
        XCTAssertNil(viewModel.attachmentNotice)
    }

    func test_activityChangeAffectsTranscriptLayout_returnsTrueWhileThinking() {
        XCTAssertTrue(
            OverlayView.activityChangeAffectsTranscriptLayout(
                from: .planning,
                to: .toolCall(label: "Calendar"),
                mode: .thinking
            )
        )
    }

    func test_activityChangeAffectsTranscriptLayout_returnsTrueForSpeakingPromptToggle() {
        XCTAssertTrue(
            OverlayView.activityChangeAffectsTranscriptLayout(
                from: .composing,
                to: .speaking,
                mode: .responding
            )
        )
    }

    func test_activityChangeAffectsTranscriptLayout_returnsFalseForNonSpeakingNonThinkingChanges() {
        XCTAssertFalse(
            OverlayView.activityChangeAffectsTranscriptLayout(
                from: .planning,
                to: .composing,
                mode: .responding
            )
        )
    }

    private static func sampleAttachment() -> StagedImageAttachment {
        return StagedImageAttachment(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            source: .fileImport,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            originalFilename: "sample.png",
            stagedFilePath: "/tmp/sample.png",
            thumbnailFilePath: "/tmp/sample-thumb.png",
            mimeType: "image/png",
            byteCount: 1024,
            pixelWidth: 640,
            pixelHeight: 480
        )
    }
}
