import Foundation

@MainActor
extension SimplePipelineController {
    // MARK: - Private - Streaming Response

    func handleStreamingToken(_ token: String) {
        switch self.state {
        case .thinking, .responding, .speaking:
            break
        default:
            self.logger.notice("PIPELINE_IGNORED_STREAM_TOKEN_OUTSIDE_RESPONSE_STATE")
            return
        }

        self.streamingResponseHandler.appendToken(
            token,
            onStreamStarted: { [weak self] in
                guard let self else { return }
                self.logger.notice("PIPELINE_STREAMING_RESPONSE_STARTED")
                self.transition(to: .responding)
                self.overlayPresenter.mode = .responding
            },
            onResponseUpdated: { [weak self] updatedText in
                guard let self else { return }
                self.currentResponse = updatedText
                self.overlayPresenter.model.addAssistantMessage(updatedText, isPartial: true)
            }
        )
    }

    func finishStreamingResponse() {
        guard self.isStreamingResponse else { return }
        self.streamingResponseHandler.finish()
        self.logger.notice("PIPELINE_STREAMING_RESPONSE_FINISHED")
    }

    func resetStreamingResponse() {
        if self.isStreamingResponse {
            self.logger.notice("PIPELINE_STREAMING_RESPONSE_RESET")
        }
        self.streamingResponseHandler.reset()
    }

    // MARK: - Private - TTS
    
    func speakResponse(_ text: String) {
        self.transition(to: .speaking)
        self.setOverlayActivity(.speaking)

        self.ttsTask = Task {
            do {
                // Get audio stream from TTS
                let audioStream = self.ttsService.speak(text)

                // Play through AudioPlaybackService
                try await AudioPlaybackService.shared.play(chunks: audioStream)

                guard !Task.isCancelled else { return }

                // TTS complete, transition to awaiting follow-up
                self.finishSpeaking()

            } catch {
                guard !Task.isCancelled else { return }

                self.logger.error("TTS playback failed: \(error.localizedDescription)")
                // Still complete - user saw the text
                self.finishSpeaking()
            }
        }
    }

    func finishSpeaking() {
        self.logger.info("TTS complete")

        self.transitionToAwaitingFollowUp(autoListen: self.isConversationModeEnabled)
    }

    func transitionToAwaitingFollowUp(autoListen: Bool) {
        // Transition to awaiting follow-up state
        self.transition(to: .awaitingFollowUp)
        self.overlayPresenter.mode = .awaitingFollowUp
        self.setOverlayActivity(.waiting)

        // Handle Conversation Mode: auto-listen after response (AC-7, AC-11)
        guard autoListen else { return }

        self.logger.info("Conversation mode enabled, scheduling follow-up")
        Task {
            // Short delay to let the user process the response
            do {
                try await Task.sleep(for: .milliseconds(Int(self.followUpAutoListenDelay * 1000)))
            } catch {
                return
            }

            // Ensure we are still in awaitingFollowUp state (user didn't cancel)
            guard !Task.isCancelled, self.state == .awaitingFollowUp else { return }

            await MainActor.run {
                self.startFollowUp()
            }
        }
    }
    
}
