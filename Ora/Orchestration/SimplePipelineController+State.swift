import Foundation

extension Notification.Name {
    /// Posted when the foreground pipeline transitions to an active state
    /// (listening, thinking, speaking, executing).
    static let oraForegroundWorkStarted = Notification.Name("oraForegroundWorkStarted")

    /// Posted when the foreground pipeline transitions to an idle or terminal state
    /// (idle, completed, error).
    static let oraForegroundWorkIdle = Notification.Name("oraForegroundWorkIdle")
}

@MainActor
extension SimplePipelineController {
    // MARK: - Private - Error Handling
    
    func handleError(_ error: Error) {
        let message = error.localizedDescription
        self.logger.error("Pipeline error: \(message)")
        self.logger.notice("PIPELINE_TURN_PROCESSING_FAILED")
        
        // Cancel any running session task
        self.sessionTask?.cancel()
        self.sessionTask = nil
        self.resetStreamingResponse()
        self.overlayPresenter.model.discardTrailingPartialAssistantMessage()
        
        // Stop audio capture to prevent resource leak
        Task {
            await self.audioService.cancel()
        }
        
        self.transition(to: .error(message))
        self.overlayPresenter.mode = .error(message)
        
        // Auto-recover after delay
        self.autoDismissTask = Task {
            do {
                try await Task.sleep(for: .seconds(self.errorRecoveryDelay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.transition(to: .idle)
            self.setOverlayActivity(.none)
            self.overlayPresenter.hide(animated: true)
            self.clearSessionImageAttachments()
        }
    }

    // MARK: - Private - State Management
    
    func transition(to newState: PipelineState) {
        let oldState = self.state
        if !self.stateMachine.canTransition(from: oldState, to: newState) {
            self.logger.error("Invalid pipeline transition attempted: \(oldState.description) -> \(newState.description)")
            return
        }
        self.state = newState

        self.logger.debug("State: \(oldState.description) → \(newState.description)")

        // Update status bar
        self.updateStatusBar(for: newState)

        // Post foreground activity notifications for background task coordination
        let wasActive = Self.isSessionActive(for: oldState)
        let isActive = Self.isSessionActive(for: newState)
        if isActive && !wasActive {
            NotificationCenter.default.post(name: .oraForegroundWorkStarted, object: nil)
        } else if !isActive && wasActive {
            NotificationCenter.default.post(name: .oraForegroundWorkIdle, object: nil)
        }
    }
    
    func updateStatusBar(for state: PipelineState) {
        let statusState = Self.statusBarState(for: state)
        switch state {
        case .idle, .completed:
            StatusBarController.shared?.setState(statusState)
        case .listening:
            StatusBarController.shared?.setState(statusState)
        case .thinking, .responding, .awaitingFollowUp, .executing:
            StatusBarController.shared?.setState(statusState)
        case .speaking:
            StatusBarController.shared?.setState(statusState)
        case .error(let message):
            StatusBarController.shared?.setState(statusState)
        }
    }

    static func isSessionActive(for state: PipelineState) -> Bool {
        switch state {
        case .idle, .completed:
            return false
        default:
            return true
        }
    }

    static func statusBarState(for state: PipelineState) -> StatusBarController.State {
        switch state {
        case .idle, .completed:
            return .idle
        case .listening:
            return .listening
        case .thinking, .responding, .awaitingFollowUp, .executing:
            return .thinking
        case .speaking:
            return .speaking
        case .error(let message):
            return .error(message)
        }
    }
}
