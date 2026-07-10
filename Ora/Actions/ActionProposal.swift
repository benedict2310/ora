import Foundation

struct ActionProposal: Sendable, Equatable {
    let action: Action
    let summary: String
    let confirmationLabel: String
    let proposalID: String?

    init(
        action: Action,
        summary: String? = nil,
        confirmationLabel: String = "Confirm",
        proposalID: String? = nil
    ) {
        self.action = action
        self.summary = summary ?? "Confirm \(action.name)."
        self.confirmationLabel = confirmationLabel
        self.proposalID = proposalID
    }

    func withProposalID(_ proposalID: String?) -> ActionProposal {
        ActionProposal(
            action: self.action,
            summary: self.summary,
            confirmationLabel: self.confirmationLabel,
            proposalID: proposalID
        )
    }

    func hasSameConfirmationContent(as other: ActionProposal) -> Bool {
        self.action == other.action &&
            self.summary == other.summary &&
            self.confirmationLabel == other.confirmationLabel
    }
}
