import Foundation

@MainActor
extension SimplePipelineController {
    // MARK: - Private - Silence Detection

    /// Set up silence detection for conversation mode
    func setupSilenceDetector() {
        // Only enable in conversation mode (AC-7)
        guard self.isConversationModeEnabled else {
            self.silenceDetector = nil
            return
        }

        self.logger.debug("Setting up silence detector")

        // Use user-configured silence timeout (AC-2, AC-3)
        let timeout = self.persistenceService.settings.silenceTimeout

        let detector = SilenceDetector(timeout: timeout)
        detector.onSilenceDetected = { [weak self] in
            guard let self = self else { return }
            guard self.state == .listening else {
                self.logger.debug("Silence detected outside listening state, ignoring")
                return
            }
            // Only auto-submit if we have a transcript (AC-6)
            guard !self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.logger.debug("Silence detected but transcript empty, ignoring")
                return
            }
            self.logger.info("Silence detected, auto-submitting")
            self.submitTranscript()
        }
        self.silenceDetector = detector
    }

    // MARK: - Private - Session Management

    func runListeningSession() async {
        do {
            guard self.inputMode == .voice else {
                self.logger.debug("Skipping audio listening session while in text input mode")
                return
            }

            defer {
                self.cancelTypingHintTimer()
            }

            // Reset ASR state for new session
            await self.asrService.reset()

            // Set up silence detection for conversation mode (AC-1, AC-7)
            self.setupSilenceDetector()
            self.startTypingHintTimer()

            // Pre-emptively track permission prompt if microphone permission is not determined
            // This prevents a race condition where the system permission dialog appears
            // before PermissionsManager has a chance to set up the tracker
            let micStatus = await PermissionsManager.shared.check(.microphone)
            let needsMicPermission = micStatus == .notDetermined
            if needsMicPermission {
                await PermissionPromptTracker.shared.beginPrompt(for: .microphone)
            }

            // Start audio capture (may trigger permission dialog)
            let audioStream: AsyncStream<AudioFrame>
            do {
                audioStream = try await self.audioService.start()
            } catch {
                // Clean up tracker if we set it up
                if needsMicPermission {
                    await PermissionPromptTracker.shared.endPrompt(for: .microphone)
                }
                throw error
            }

            // Clean up pre-emptive tracker - PermissionsManager handles its own tracking
            if needsMicPermission {
                await PermissionPromptTracker.shared.endPrompt(for: .microphone)
            }

            // Start transcription with VAD callback
            // VAD state changes drive the silence detector timeout
            let asrStream = self.asrService.transcribe(
                frames: audioStream,
                onVADStateChange: { [weak self] isSpeech in
                    // Wire VAD state changes to silence detector (AC-4, AC-5)
                    self?.silenceDetector?.onVADStateChanged(isSpeech: isSpeech)
                    if isSpeech {
                        self?.cancelTypingHintForVoiceActivity()
                    }
                }
            )

            // Process ASR events
            for try await event in asrStream {
                guard !Task.isCancelled else {
                    self.logger.debug("Session cancelled during ASR")
                    return
                }

                switch event {
                case .partial(let text, _):
                    self.currentTranscript = text
                    self.overlayPresenter.model.addUserMessage(text, isPartial: true)
                    // Notify silence detector of new partial (AC-7)
                    self.silenceDetector?.onPartialReceived(text: text)
                    self.cancelTypingHintForVoiceActivity()

                case .final(let text):
                    self.currentTranscript = text
                    let thumbnails = self.pendingImageAttachments.compactMap(\.thumbnailFileURL)
                    self.overlayPresenter.model.addUserMessage(text, isPartial: false, thumbnailURLs: thumbnails)
                    self.cancelTypingHintForVoiceActivity()
                }
            }
            
            // ASR stream ended - check if we have a transcript to process
            guard !Task.isCancelled else {
                self.logger.debug("Session cancelled after ASR")
                return
            }
            
            // Empty transcript returns to awaiting follow-up without agent processing
            if self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.logger.info("Empty transcript, transitioning to awaitingFollowUp")
                self.transition(to: .awaitingFollowUp)
                self.overlayPresenter.mode = .awaitingFollowUp
                self.cancelTypingHintTimer()
                return
            }
            
            // Process the transcript with AgentLoop
            await self.processTranscript()
            
        } catch {
            guard !Task.isCancelled else {
                self.logger.debug("Session cancelled during error: \(error.localizedDescription)")
                return
            }
            
            self.handleError(error)
        }
    }
    
}
