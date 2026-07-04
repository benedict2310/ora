import Foundation

enum ActionHostError: LocalizedError, Sendable, Equatable {
    case unsupportedAction(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let name):
            return "Unsupported action: \(name)"
        }
    }
}

enum ActionApproval: Sendable, Equatable {
    case approved
}

struct ActionCatalog: Sendable, Equatable {
    let actions: [Action]

    func action(named name: String) -> Action? {
        self.actions.first { $0.name == name }
    }

    static let v2Default = ActionCatalog(actions: Action.v2DefaultActions)
}

protocol ActionHosting: Sendable {
    var catalog: ActionCatalog { get }
    func execute(actionNamed name: String, approval: ActionApproval?) async throws -> ActionResult
}

struct ActionHost: ActionHosting {
    let catalog: ActionCatalog

    init(catalog: ActionCatalog = .v2Default) {
        self.catalog = catalog
    }

    func execute(actionNamed name: String, approval: ActionApproval? = nil) async throws -> ActionResult {
        guard let action = self.catalog.action(named: name) else {
            throw ActionHostError.unsupportedAction(name)
        }

        if action.requiresConfirmation, approval != .approved {
            return .proposed(ActionProposal(action: action))
        }

        return .executed(action: action, summary: "\(action.name) executed.")
    }
}
