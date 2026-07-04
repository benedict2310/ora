import Foundation

enum ActionResult: Sendable, Equatable {
    case executed(action: Action, summary: String)
    case proposed(ActionProposal)
}
