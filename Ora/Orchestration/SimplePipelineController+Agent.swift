import Foundation

@MainActor
extension SimplePipelineController {
    // MARK: - Private - Agent Processing
    
    func processTranscript() async {
        self.logger.info("Processing transcript: \(self.currentTranscript.prefix(50))...")
        self.logger.notice("PIPELINE_TURN_PROCESSING_STARTED")

        let turnAttachments = self.consumePendingImageAttachmentsForTurn()
        let turnAttachmentIDs = turnAttachments.map(\.id)
        self.currentResponse = ""
        self.resetStreamingResponse()
        self.overlayPresenter.model.discardTrailingPartialAssistantMessage()
        self.transition(to: .thinking)
        self.overlayPresenter.mode = .thinking
        
        do {
            // Preflight provider/model readiness to avoid generic startup failures.
            let preflight = await LLMProviderManager.shared.preflightForConversationStart()
            if case .guidance(let guidance) = preflight {
                await self.attachmentStore.removeAttachments(ids: turnAttachmentIDs)
                self.handleAgentError(guidance)
                return
            }

            // Ensure LLM is ready
            try await LLMProviderManager.shared.prepare()
            self.sessionImageAttachmentIDs.formUnion(turnAttachmentIDs)
            
            // Process through agent loop (session preserves conversation context)
            let result = try await self.agentLoop.process(
                userText: self.currentTranscript,
                imageAttachments: turnAttachments.map(\.llmReference)
            )
            
            guard !Task.isCancelled else {
                self.logger.debug("Session cancelled after agent processing")
                return
            }
            
            switch result {
            case .response(let text):
                self.handleAgentResponse(text)
                
            case .authorizationRequest(let proposal):
                self.handleAgentProposal(proposal)
                
            case .error(let message):
                self.handleAgentError(message)
            }
            
        } catch {
            self.sessionImageAttachmentIDs.subtract(turnAttachmentIDs)
            await self.attachmentStore.removeAttachments(ids: turnAttachmentIDs)
            guard !Task.isCancelled else { return }
            self.handleError(error)
        }
    }
    
    func handleAgentResponse(_ text: String) {
        self.logger.info("Agent response: \(text.prefix(50))...")
        self.logger.notice("PIPELINE_TURN_RECEIVED_RESPONSE")
        
        self.currentResponse = text

        if self.isStreamingResponse {
            self.overlayPresenter.model.addAssistantMessage(text, isPartial: false)
            self.finishStreamingResponse()
            self.speakResponse(text)
            return
        }
        
        self.transition(to: .responding)
        self.overlayPresenter.mode = .responding
        
        // Add assistant message to overlay
        self.overlayPresenter.model.addAssistantMessage(text, isPartial: false)
        
        // Speak the response (AC-9)
        self.speakResponse(text)
    }
    
    func handleAgentProposal(_ proposal: ToolProposal) {
        self.logger.info("Agent proposal: \(proposal.summary) (tool: \(proposal.toolName))")

        self.overlayPresenter.model.showProposal(proposal)
        
        // State is now proposing - wait for user confirmation/denial via notifications
        // No TTS until after confirmation (per TTS Integration Notes)
    }
    
    func handleAgentError(_ message: String) {
        self.logger.warning("Agent error: \(message)")
        self.logger.notice("PIPELINE_TURN_RECEIVED_ERROR")
        
        self.currentResponse = message
        if self.isStreamingResponse {
            self.logger.notice("PIPELINE_TURN_ERROR_DURING_STREAMING")
        }
        self.resetStreamingResponse()
        self.overlayPresenter.model.discardTrailingPartialAssistantMessage()
        
        // Show error in overlay (no TTS for errors)
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
            self.transition(to: .awaitingFollowUp)
            self.overlayPresenter.mode = .awaitingFollowUp
            self.setOverlayActivity(.waiting)
        }
    }

    // MARK: - Private - Proposal Handling
    
    func handleProposalConfirmed() {
        self.logger.info("Proposal confirmed by user")
        
        // Transition to executing state
        self.transition(to: .executing)
        self.overlayPresenter.mode = .executing
        
        self.confirmationTask = Task {
            await self.executeConfirmedProposal()
        }
    }
    
    func handleProposalDenied() {
        self.logger.info("Proposal denied by user")

        // Clear the pending proposal
        Task {
            await self.agentLoop.clearPendingAuthorization()
        }

        // Return to awaiting follow-up without executing (AC-6)
        self.transition(to: .awaitingFollowUp)
        self.overlayPresenter.mode = .awaitingFollowUp
        self.setOverlayActivity(.waiting)
    }

    func handleProposalConfirmedAndTrust() {
        self.logger.info("Proposal confirmed by user with trust grant")

        self.transition(to: .executing)
        self.overlayPresenter.mode = .executing

        self.confirmationTask = Task {
            await self.executeAuthorizedProposal(decision: .approveAndTrust)
        }
    }

    func executeConfirmedProposal() async {
        await self.executeAuthorizedProposal(decision: .approveOnce)
    }

    func executeAuthorizedProposal(decision: ToolAuthorizationDecision) async {
        guard await self.agentLoop.getPendingAuthorization() != nil else {
            self.logger.error("No pending proposal to execute")
            self.transition(to: .awaitingFollowUp)
            self.overlayPresenter.mode = .awaitingFollowUp
            return
        }
        
        do {
            _ = try await self.agentLoop.executeAuthorizedPending(decision: decision)
            
            guard !Task.isCancelled else { return }
            
            // Ensure overlay is still visible and app is active
            // (permission dialogs may have stolen focus)
            self.overlayPresenter.show()
            
            // Generate follow-up response
            self.transition(to: .responding)
            self.overlayPresenter.mode = .responding
            
            let followUpText = try await self.agentLoop.generateFollowUp()
            
            guard !Task.isCancelled else { return }
            
            self.currentResponse = followUpText

            // Add follow-up message to overlay
            self.overlayPresenter.model.addAssistantMessage(followUpText, isPartial: false)

            // Speak the follow-up response (AC-10)
            if self.isStreamingResponse {
                self.finishStreamingResponse()
                self.speakResponse(followUpText)
            } else {
                self.speakResponse(followUpText)
            }
            
        } catch {
            guard !Task.isCancelled else { return }
            
            self.logger.error("Tool execution failed: \(error.localizedDescription)")
            self.handleAgentError("I couldn't complete that action: \(error.localizedDescription)")
        }
    }

}
