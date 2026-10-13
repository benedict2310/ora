import Foundation

struct AssistantTextRequest: Sendable, Equatable {
    let turnID: TelemetryTurnID
    let text: String
}

struct AssistantTurnResult: Sendable, Equatable {
    let turnID: TelemetryTurnID
    let message: String
}

struct AssistantTurnProposal: Sendable, Equatable {
    let turnID: TelemetryTurnID
    let proposal: ActionProposal
    let message: String
}

struct AssistantTurnFailure: Sendable, Equatable {
    let turnID: TelemetryTurnID
    let message: String
}

struct AssistantTurnCancellation: Sendable, Equatable {
    let turnID: TelemetryTurnID
    let message: String
}

enum AssistantTurnOutcome: Sendable, Equatable {
    case result(AssistantTurnResult)
    case proposal(AssistantTurnProposal)
    case failure(AssistantTurnFailure)
    case cancelled(AssistantTurnCancellation)
}
