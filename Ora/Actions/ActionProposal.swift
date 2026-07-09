import Foundation

struct ActionProposal: Sendable, Equatable {
    let action: Action
    let summary: String
    let confirmationLabel: String

    init(
        action: Action,
        summary: String? = nil,
        confirmationLabel: String = "Confirm"
    ) {
        self.action = action
        self.summary = summary ?? "Confirm \(action.name)."
        self.confirmationLabel = confirmationLabel
    }
}
