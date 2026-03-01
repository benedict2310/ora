import Foundation

@MainActor
final class ConfirmationHandler: OverlayActionHandling {

    var onConfirmProposal: (() -> Void)?
    var onConfirmAndTrustProposal: (() -> Void)?
    var onDenyProposal: (() -> Void)?
    var onStopSpeaking: (() -> Void)?

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
}
