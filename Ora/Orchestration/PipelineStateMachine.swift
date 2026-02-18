import Foundation

struct PipelineStateMachine {

    func canTransition(from current: PipelineState, to next: PipelineState) -> Bool {
        if current == next {
            return true
        }

        switch current {
        case .idle:
            return matches(next, [.listening, .error("")])

        case .listening:
            return matches(next, [.thinking, .idle, .error("")])

        case .thinking:
            return matches(next, [.responding, .executing, .awaitingFollowUp, .idle, .error("")])

        case .responding:
            return matches(next, [.speaking, .awaitingFollowUp, .idle, .error("")])

        case .speaking:
            return matches(next, [.awaitingFollowUp, .idle, .error("")])

        case .awaitingFollowUp:
            return matches(next, [.listening, .idle, .thinking, .error("")])

        case .executing:
            return matches(next, [.responding, .awaitingFollowUp, .idle, .error("")])

        case .completed:
            return matches(next, [.idle])

        case .error:
            return matches(next, [.idle, .listening, .awaitingFollowUp, .error("")])
        }
    }

    private func matches(_ state: PipelineState, _ allowed: [PipelineState]) -> Bool {
        for candidate in allowed {
            switch (state, candidate) {
            case (.error, .error):
                return true
            default:
                if state == candidate {
                    return true
                }
            }
        }
        return false
    }
}
