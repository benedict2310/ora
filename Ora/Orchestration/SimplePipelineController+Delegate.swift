import AppKit

// MARK: - StatusBarController Extension

extension StatusBarController {
    /// Shared instance accessed via AppDelegate
    @MainActor
    static var shared: StatusBarController? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return nil }
        return appDelegate.statusBarController
    }
}

// MARK: - AgentLoopDelegate

extension SimplePipelineController: AgentLoopDelegate {
    func agentLoopDidStartThinking(_ loop: AgentLoop) {}

    func agentLoop(_ loop: AgentLoop, didProduceToken token: String) {
        self.handleStreamingToken(token)
    }

    func agentLoop(_ loop: AgentLoop, didRequestConfirmation proposal: ToolProposal) {}

    func agentLoop(_ loop: AgentLoop, didExecuteTool name: String, result: String) {}

    func agentLoop(_ loop: AgentLoop, didUpdateActivity activity: AgentActivity) {
        self.updateOverlayActivity(from: activity)
    }
}

// MARK: - Activity Updates

extension SimplePipelineController {
    /// Map AgentActivity to OverlayActivity and update the overlay
    func updateOverlayActivity(from agentActivity: AgentActivity) {
        let overlayActivity: OverlayActivity
        switch agentActivity {
        case .planning:
            overlayActivity = .planning
        case .toolCall(let name):
            let label = OverlayActivity.toolLabel(for: name)
            overlayActivity = .toolCall(label: label)
        case .toolResult(let name):
            let label = OverlayActivity.toolLabel(for: name)
            overlayActivity = .toolResult(label: label)
        case .composing:
            overlayActivity = .composing
        case .waiting:
            overlayActivity = .waiting
        }
        self.overlayPresenter.model.setActivity(overlayActivity)
    }

    /// Set the overlay activity directly
    func setOverlayActivity(_ activity: OverlayActivity) {
        self.overlayPresenter.model.setActivity(activity)
    }
}
