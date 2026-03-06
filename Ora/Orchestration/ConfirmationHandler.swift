import Foundation

@MainActor
final class ConfirmationHandler: OverlayActionHandling {

    var onConfirmProposal: (() -> Void)?
    var onConfirmAndTrustProposal: (() -> Void)?
    var onDenyProposal: (() -> Void)?
    var onStopSpeaking: (() -> Void)?
    var onPasteImageAttachment: (() -> Void)?
    var onChooseImageAttachmentFile: (() -> Void)?
    var onCaptureScreenshotAttachment: (() -> Void)?
    var onRemovePendingImageAttachment: ((UUID) -> Void)?
    var onClearPendingImageAttachments: (() -> Void)?
    var onOpenScreenRecordingSettings: (() -> Void)?

    func confirmToolProposal() {
        self.onConfirmProposal?()
    }

    func confirmAndTrustToolProposal() {
        self.onConfirmAndTrustProposal?()
    }

    func denyToolProposal() {
        self.onDenyProposal?()
    }

    func stopSpeechPlayback() {
        self.onStopSpeaking?()
    }

    func pasteImageAttachment() {
        self.onPasteImageAttachment?()
    }

    func chooseImageAttachmentFile() {
        self.onChooseImageAttachmentFile?()
    }

    func captureScreenshotAttachment() {
        self.onCaptureScreenshotAttachment?()
    }

    func removePendingImageAttachment(_ id: UUID) {
        self.onRemovePendingImageAttachment?(id)
    }

    func clearPendingImageAttachments() {
        self.onClearPendingImageAttachments?()
    }

    func openScreenRecordingSettings() {
        self.onOpenScreenRecordingSettings?()
    }
}
