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
        // Skip TTS in text mode — the user is reading, not listening
        if self.inputMode == .text {
            self.finishSpeaking()
            return
        }

        self.ttsTask?.cancel()
        self.transition(to: .speaking)
        self.setOverlayActivity(.speaking)

        let latencyContext: LegacyVoiceLatencyContext?
        if let turn = self.currentVoiceLatencyTurn {
            let attempt = self.legacyVoiceLatencyObserver.beginAttempt(for: turn)
            self.currentVoiceLatencyAttempt = attempt
            latencyContext = LegacyVoiceLatencyContext(
                attempt: attempt,
                observer: self.legacyVoiceLatencyObserver
            )
        } else {
            latencyContext = nil
        }

        self.ttsTask = Task {
            do {
                try Task.checkCancellation()
                // Get audio stream from TTS
                let audioStream = self.ttsService.speak(text, latencyContext: latencyContext)

                // Play through AudioPlaybackService
                try await self.playbackService.play(
                    chunks: audioStream,
                    latencyContext: latencyContext
                )

                guard !Task.isCancelled else {
                    if let latencyContext {
                        latencyContext.attempt.complete(
                            by: latencyContext.observer,
                            outcome: .cancelled,
                            reason: "task_cancelled"
                        )
                    }
                    return
                }

                guard self.currentVoiceLatencyAttempt == latencyContext?.attempt else { return }
                self.currentVoiceLatencyAttempt = nil
                // Only the still-current attempt may transition controller state.
                self.finishSpeaking()

            } catch is CancellationError {
                if let latencyContext {
                    latencyContext.attempt.complete(
                        by: latencyContext.observer,
                        outcome: .cancelled,
                        reason: "cancelled"
                    )
                }
            } catch is AudioPlaybackError {
                if let latencyContext {
                    latencyContext.attempt.complete(
                        by: latencyContext.observer,
                        outcome: .error,
                        reason: "playback_error"
                    )
                }
                guard !Task.isCancelled,
                      self.currentVoiceLatencyAttempt == latencyContext?.attempt else { return }
                self.currentVoiceLatencyAttempt = nil
                self.logger.error("TTS playback failed")
                self.finishSpeaking()
            } catch {
                if let latencyContext {
                    latencyContext.attempt.complete(
                        by: latencyContext.observer,
                        outcome: .error,
                        reason: "synthesis_error"
                    )
                }
                guard !Task.isCancelled,
                      self.currentVoiceLatencyAttempt == latencyContext?.attempt else { return }
                self.currentVoiceLatencyAttempt = nil
                self.logger.error("TTS playback failed")
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
        if self.inputMode == .text {
            self.overlayPresenter.model.isTextInputVisible = false
            self.overlayPresenter.model.textInputText = ""
        }

        // Handle Conversation Mode: auto-listen after response (AC-7, AC-11)
        guard autoListen, self.inputMode == .voice else { return }

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
