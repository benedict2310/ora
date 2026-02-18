import Foundation

@MainActor
final class ConfirmationHandler: OverlayActionHandling {

    var onConfirmProposal: (() -> Void)?
    var onDenyProposal: (() -> Void)?
    var onStopSpeaking: (() -> Void)?

    func confirmToolProposal() {
        self.onConfirmProposal?()
    }

    func denyToolProposal() {
        self.onDenyProposal?()
    }

    func stopSpeechPlayback() {
        self.onStopSpeaking?()
    }
}
