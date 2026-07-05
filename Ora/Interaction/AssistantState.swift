import Foundation

enum AssistantState: Sendable, Equatable {
    case idle
    case listening
    case thinking
    case responding
    case awaitingFollowUp
    case error(String)
}

enum AssistantEvent: Sendable, Equatable {
    case startListening
    case submitTranscript
    case startResponding
    case finishResponse
    case cancel
    case fail(String)
}

enum AssistantStateTransitionError: Error, Sendable, Equatable {
    case invalidTransition(from: AssistantState, event: AssistantEvent)
}

extension AssistantState {
    func transition(on event: AssistantEvent) throws -> AssistantState {
        switch (self, event) {
        case (.idle, .startListening):
            return .listening
        case (.listening, .submitTranscript):
            return .thinking
        case (.thinking, .startResponding):
            return .responding
        case (.responding, .finishResponse):
            return .awaitingFollowUp
        case (.awaitingFollowUp, .startListening):
            return .listening
        case (.listening, .cancel):
            return .idle
        case (.idle, .fail(let message)), (.listening, .fail(let message)):
            return .error(message)
        default:
            throw AssistantStateTransitionError.invalidTransition(from: self, event: event)
        }
    }
}
