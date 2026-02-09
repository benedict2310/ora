//
//  SimplePipelineController.swift
//  Ora
//
//  ASR → AgentLoop → TTS pipeline coordinator with tool execution support.
//

import Foundation
import AppKit
import os
import Combine
import SwiftData

/// Coordinates ASR → AgentLoop → TTS pipeline with tool proposals and execution
///
/// ## State Machine
/// ```
/// idle ──(hotkey press)──► listening ──(submit)──► thinking
///   ▲                          │                       │
///   │                       (cancel)                   ▼
///   │                          │              ┌─── responding ───┐
///   │                          ▼              │                  │
///   └─────────────────────── idle ◄───────────┤   speaking       │
///                              ▲              │       ▼          │
///                              │              └─► awaitingFollowUp
///                              │                       │
///                              │              ┌───────────────────┐
///                              │              │    proposing      │
///                              │              │   (confirm/deny)  │
///                              │              └───────────────────┘
///                              │                       │
///                              │              ┌─── executing ────┐
///                              │              │       ▼          │
///                              └──────────────┤   speaking       │
///                                             └─► awaitingFollowUp
/// ```
@MainActor
final class SimplePipelineController: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = SimplePipelineController()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "Pipeline")
    
    @Published private(set) var state: PipelineState = .idle
    @Published private(set) var currentTranscript: String = ""
    @Published private(set) var currentResponse: String = ""
    
    private var sessionTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var sentenceChunker: SentenceChunker?
    private var sentenceStreamContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var isStreamingResponse = false
    // Keep TTS full-response while UI streams.
    private let usesStreamingTTS = false
    
    /// The agent loop for processing requests
    private let agentLoop: AgentLoop

    /// Silence detector for auto-submit in conversation mode
    private var silenceDetector: SilenceDetector?

    /// Observers for proposal confirmation/denial
    /// Using nonisolated(unsafe) since these are only accessed from MainActor
    /// and this is a singleton that lives for the app's lifetime
    nonisolated(unsafe) private var proposalConfirmObserver: NSObjectProtocol?
    nonisolated(unsafe) private var proposalDenyObserver: NSObjectProtocol?
    nonisolated(unsafe) private var speechStopObserver: NSObjectProtocol?
    
    /// Delay before auto-recovering from error (seconds)
    private let errorRecoveryDelay: TimeInterval = 3.0
    /// Delay before auto-starting follow-up listening (conversation mode)
    private let followUpAutoListenDelay: TimeInterval = 0.5
    
    /// Whether conversation mode is enabled (combines silence detection + auto-listen)
    private var isConversationModeEnabled: Bool {
        return self.fetchConversationModeSetting()
    }

    /// Whether there is an active conversation session
    var isSessionActive: Bool {
        Self.isSessionActive(for: self.state)
    }

    // MARK: - Initialization
    
    private init(agentLoop: AgentLoop = AgentLoop()) {
        self.agentLoop = agentLoop
        self.setupProposalObservers()
        Task { @MainActor in
            self.agentLoop.setDelegate(self)
        }
    }
    
    private func fetchConversationModeSetting() -> Bool {
        return PersistenceManager.shared.settings.conversationModeEnabled
    }
    
    /// Create a test instance with injectable agent loop
    static func makeTestInstance(agentLoop: AgentLoop? = nil) -> SimplePipelineController {
        return SimplePipelineController(agentLoop: agentLoop ?? AgentLoop())
    }
    
    // MARK: - Proposal Observers
    
    private func setupProposalObservers() {
        self.proposalConfirmObserver = NotificationCenter.default.addObserver(
            forName: .proposalConfirmed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleProposalConfirmed()
        }
        
        self.proposalDenyObserver = NotificationCenter.default.addObserver(
            forName: .proposalDenied,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleProposalDenied()
        }

        self.speechStopObserver = NotificationCenter.default.addObserver(
            forName: .speechStopRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.interruptSpeech()
        }
    }
    
    deinit {
        if let observer = proposalConfirmObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = proposalDenyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = speechStopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Public API
    
    /// Start listening or toggle (hotkey pressed)
    func startListening() {
        // If overlay is visible and we are in a session, pressing hotkey should cancel
        if OverlayWindowController.shared.isVisible {
            self.logger.info("Hotkey pressed while overlay visible - cancelling")
            self.cancel()
            return
        }
        
        // Cancel any pending auto-dismiss (legacy check)
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        
        // Cancel any existing session
        self.sessionTask?.cancel()
        
        // Reset state for new session
        self.currentTranscript = ""
        self.currentResponse = ""
        self.resetStreamingResponse()
        
        // Reset overlay for new session
        self.logger.info("Resetting overlay for new session")
        OverlayWindowController.shared.model.reset()
        
        self.transition(to: .listening)

        // Show overlay in listening mode with activity
        OverlayWindowController.shared.mode = .listening
        self.setOverlayActivity(.listening)
        OverlayWindowController.shared.show()
        
        // Start the session task
        self.sessionTask = Task {
            // Initialize agent session (with tool definitions)
            await self.agentLoop.startSession()
            await self.runListeningSession()
        }
        
        self.logger.info("Started listening")
    }
    
    /// Submit transcript manually (Enter key) or via silence detection
    func submitTranscript() {
        guard self.state == .listening else {
            self.logger.warning("Cannot submit transcript in state: \(self.state.description)")
            return
        }

        self.logger.debug("Submitting transcript")

        // Cancel silence detector to prevent double-submit (AC-9)
        self.silenceDetector?.cancel()

        // Stop audio capture - this will cause the ASR stream to finalize
        Task {
            await AudioService.shared.stop()
        }
    }
    
    /// Start follow-up recording (from awaiting follow-up)
    func startFollowUp() {
        guard self.state == .awaitingFollowUp else {
            self.logger.warning("Cannot start follow-up in state: \(self.state.description)")
            return
        }
        
        self.logger.info("Starting follow-up")

        self.transition(to: .listening)
        OverlayWindowController.shared.mode = .listening
        self.setOverlayActivity(.listening)
        
        // Reset current transcript for new turn
        self.currentTranscript = ""
        
        // Start listening again (keeping conversation history via agent loop session)
        self.sessionTask = Task {
            await self.runListeningSession()
        }
    }
    
    /// Stop listening (Legacy/Unused for tap-to-talk)
    func stopListening() {
        // No-op for tap-to-talk flow
    }
    
    /// Cancel current operation and return to idle (AC-10)
    func cancel() {
        self.logger.info("Cancelling current operation from state: \(self.state.description)")

        // Cancel silence detector
        self.silenceDetector?.cancel()
        self.silenceDetector = nil

        // Cancel all tasks
        self.sessionTask?.cancel()
        self.sessionTask = nil
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        self.ttsTask?.cancel()
        self.ttsTask = nil
        self.confirmationTask?.cancel()
        self.confirmationTask = nil
        self.resetStreamingResponse()

        // Stop audio capture and TTS playback
        Task {
            await TTSService.shared.stop()
            await AudioPlaybackService.shared.stop()
            await AudioService.shared.cancel()
            await self.agentLoop.endSession()
            await self.agentLoop.clearPendingProposal()
        }

        self.transition(to: .idle)
        self.setOverlayActivity(.none)
        OverlayWindowController.shared.hide(animated: true)
    }

    /// Stop speaking without closing the overlay
    func interruptSpeech() {
        guard self.state == .speaking else {
            self.logger.debug("Ignoring interruptSpeech in state: \(self.state.description)")
            return
        }

        self.logger.info("Interrupting TTS playback")

        self.ttsTask?.cancel()
        self.ttsTask = nil

        Task {
            await TTSService.shared.stop()
            await AudioPlaybackService.shared.stop()
        }

        self.transitionToAwaitingFollowUp(autoListen: self.isConversationModeEnabled)
    }

    // MARK: - Private - Silence Detection

    /// Set up silence detection for conversation mode
    private func setupSilenceDetector() {
        // Only enable in conversation mode (AC-7)
        guard self.isConversationModeEnabled else {
            self.silenceDetector = nil
            return
        }

        self.logger.debug("Setting up silence detector")

        // Use user-configured silence timeout (AC-2, AC-3)
        let timeout = PersistenceManager.shared.settings.silenceTimeout

        let detector = SilenceDetector(timeout: timeout)
        detector.onSilenceDetected = { [weak self] in
            guard let self = self else { return }
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

    private func runListeningSession() async {
        do {
            // Reset ASR state for new session
            await ASRService.shared.reset()

            // Set up silence detection for conversation mode (AC-1, AC-7)
            self.setupSilenceDetector()

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
                audioStream = try await AudioService.shared.start()
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
            let asrStream = await ASRService.shared.transcribe(
                frames: audioStream,
                onVADStateChange: { [weak self] isSpeech in
                    // Wire VAD state changes to silence detector (AC-4, AC-5)
                    self?.silenceDetector?.onVADStateChanged(isSpeech: isSpeech)
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
                    OverlayWindowController.shared.model.addUserMessage(text, isPartial: true)
                    // Notify silence detector of new partial (AC-7)
                    self.silenceDetector?.onPartialReceived(text: text)

                case .final(let text):
                    self.currentTranscript = text
                    OverlayWindowController.shared.model.addUserMessage(text, isPartial: false)
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
                OverlayWindowController.shared.mode = .awaitingFollowUp
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
    
    // MARK: - Private - Agent Processing
    
    private func processTranscript() async {
        self.logger.info("Processing transcript: \(self.currentTranscript.prefix(50))...")
        
        self.currentResponse = ""
        self.resetStreamingResponse()
        self.transition(to: .thinking)
        OverlayWindowController.shared.mode = .thinking
        
        do {
            // Preflight provider/model readiness to avoid generic startup failures.
            let preflight = await LLMProviderManager.shared.preflightForConversationStart()
            if case .guidance(let guidance) = preflight {
                self.handleAgentError(guidance)
                return
            }

            // Ensure LLM is ready
            try await LLMProviderManager.shared.prepare()
            
            // Process through agent loop (session preserves conversation context)
            let result = try await self.agentLoop.process(userText: self.currentTranscript)
            
            guard !Task.isCancelled else {
                self.logger.debug("Session cancelled after agent processing")
                return
            }
            
            switch result {
            case .response(let text):
                self.handleAgentResponse(text)
                
            case .proposal(let summary, let tool, _):
                self.handleAgentProposal(summary: summary, tool: tool)
                
            case .error(let message):
                self.handleAgentError(message)
            }
            
        } catch {
            guard !Task.isCancelled else { return }
            self.handleError(error)
        }
    }
    
    private func handleAgentResponse(_ text: String) {
        self.logger.info("Agent response: \(text.prefix(50))...")
        
        self.currentResponse = text

        if self.isStreamingResponse {
            OverlayWindowController.shared.model.addAssistantMessage(text, isPartial: false)
            self.finishStreamingResponse()
            if !self.usesStreamingTTS {
                self.speakResponse(text)
            }
            return
        }
        
        self.transition(to: .responding)
        OverlayWindowController.shared.mode = .responding
        
        // Add assistant message to overlay
        OverlayWindowController.shared.model.addAssistantMessage(text, isPartial: false)
        
        // Speak the response (AC-9)
        self.speakResponse(text)
    }
    
    private func handleAgentProposal(summary: String, tool: String) {
        self.logger.info("Agent proposal: \(summary) (tool: \(tool))")
        
        // Show proposal in overlay for user confirmation (AC-4)
        let proposal = ToolProposal(toolName: tool, summary: summary, details: nil)
        OverlayWindowController.shared.model.showProposal(proposal)
        
        // State is now proposing - wait for user confirmation/denial via notifications
        // No TTS until after confirmation (per TTS Integration Notes)
    }
    
    private func handleAgentError(_ message: String) {
        self.logger.warning("Agent error: \(message)")
        
        self.currentResponse = message
        
        // Show error in overlay (no TTS for errors)
        self.transition(to: .error(message))
        OverlayWindowController.shared.mode = .error(message)
        
        // Auto-recover after delay
        self.autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(self.errorRecoveryDelay))
            guard !Task.isCancelled else { return }
            self.transition(to: .awaitingFollowUp)
            OverlayWindowController.shared.mode = .awaitingFollowUp
            self.setOverlayActivity(.waiting)
        }
    }

    // MARK: - Private - Proposal Handling
    
    private func handleProposalConfirmed() {
        self.logger.info("Proposal confirmed by user")
        
        // Transition to executing state
        self.transition(to: .executing)
        OverlayWindowController.shared.mode = .executing
        
        self.confirmationTask = Task {
            await self.executeConfirmedProposal()
        }
    }
    
    private func handleProposalDenied() {
        self.logger.info("Proposal denied by user")

        // Clear the pending proposal
        Task {
            await self.agentLoop.clearPendingProposal()
        }

        // Return to awaiting follow-up without executing (AC-6)
        self.transition(to: .awaitingFollowUp)
        OverlayWindowController.shared.mode = .awaitingFollowUp
        self.setOverlayActivity(.waiting)
    }
    
    private func executeConfirmedProposal() async {
        // Get pending proposal from agent loop
        guard let proposal = await self.agentLoop.getPendingProposal() else {
            self.logger.error("No pending proposal to execute")
            self.transition(to: .awaitingFollowUp)
            OverlayWindowController.shared.mode = .awaitingFollowUp
            return
        }
        
        do {
            // Execute the tool via ToolHost (AC-5)
            _ = try await self.agentLoop.executeConfirmedTool(
                tool: proposal.tool,
                args: proposal.args
            )
            
            guard !Task.isCancelled else { return }
            
            // Ensure overlay is still visible and app is active
            // (permission dialogs may have stolen focus)
            OverlayWindowController.shared.show()
            
            // Generate follow-up response
            self.transition(to: .responding)
            OverlayWindowController.shared.mode = .responding
            
            let followUpText = try await self.agentLoop.generateFollowUp()
            
            guard !Task.isCancelled else { return }
            
            self.currentResponse = followUpText

            // Add follow-up message to overlay
            OverlayWindowController.shared.model.addAssistantMessage(followUpText, isPartial: false)

            // Speak the follow-up response (AC-10)
            // Check if streaming TTS already started (via delegate tokens)
            if self.isStreamingResponse {
                self.finishStreamingResponse()
                if !self.usesStreamingTTS {
                    self.speakResponse(followUpText)
                }
            } else {
                self.speakResponse(followUpText)
            }
            
        } catch {
            guard !Task.isCancelled else { return }
            
            self.logger.error("Tool execution failed: \(error.localizedDescription)")
            self.handleAgentError("I couldn't complete that action: \(error.localizedDescription)")
        }
    }

    // MARK: - Private - Streaming Response

    private func handleStreamingToken(_ token: String) {
        guard !token.isEmpty else { return }

        self.beginStreamingResponseIfNeeded()
        self.currentResponse += token
        OverlayWindowController.shared.model.addAssistantMessage(self.currentResponse, isPartial: true)

        if self.usesStreamingTTS, var chunker = self.sentenceChunker {
            let sentences = chunker.consume(token)
            self.sentenceChunker = chunker
            self.enqueueSentenceChunks(sentences)
        }
    }

    private func beginStreamingResponseIfNeeded() {
        guard !self.isStreamingResponse else { return }

        self.isStreamingResponse = true
        self.transition(to: .responding)
        OverlayWindowController.shared.mode = .responding

        guard self.usesStreamingTTS else { return }

        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error> { streamContinuation in
            continuation = streamContinuation
        }

        self.sentenceStreamContinuation = continuation
        self.sentenceChunker = SentenceChunker()
        self.startStreamingSpeech(sentenceStream: stream)
    }

    private func enqueueSentenceChunks(_ sentences: [String]) {
        guard let continuation = self.sentenceStreamContinuation else { return }
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            continuation.yield(trimmed)
        }
    }

    private func finishStreamingResponse() {
        guard self.isStreamingResponse else { return }
        self.isStreamingResponse = false

        if self.usesStreamingTTS {
            if var chunker = self.sentenceChunker {
                let remaining = chunker.finalize()
                self.sentenceChunker = nil
                self.enqueueSentenceChunks(remaining)
            }

            self.sentenceStreamContinuation?.finish()
            self.sentenceStreamContinuation = nil
        } else {
            self.sentenceChunker = nil
            self.sentenceStreamContinuation = nil
        }
    }

    private func resetStreamingResponse() {
        self.sentenceStreamContinuation?.finish()
        self.sentenceStreamContinuation = nil
        self.sentenceChunker = nil
        self.isStreamingResponse = false
    }

    // MARK: - Private - TTS

    private func startStreamingSpeech(sentenceStream: AsyncThrowingStream<String, Error>) {
        self.transition(to: .speaking)
        self.setOverlayActivity(.speaking)

        self.ttsTask = Task {
            do {
                let audioStream = TTSService.shared.speak(sentences: sentenceStream)
                try await AudioPlaybackService.shared.play(chunks: audioStream)

                guard !Task.isCancelled else { return }
                self.finishSpeaking()
            } catch {
                guard !Task.isCancelled else { return }
                self.logger.error("Streaming TTS playback failed: \(error.localizedDescription)")
                self.finishSpeaking()
            }
        }
    }
    
    private func speakResponse(_ text: String) {
        self.transition(to: .speaking)
        self.setOverlayActivity(.speaking)

        self.ttsTask = Task {
            do {
                // Get audio stream from TTS
                let audioStream = TTSService.shared.speak(text)

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

    private func finishSpeaking() {
        self.logger.info("TTS complete")

        self.transitionToAwaitingFollowUp(autoListen: self.isConversationModeEnabled)
    }

    private func transitionToAwaitingFollowUp(autoListen: Bool) {
        // Transition to awaiting follow-up state
        self.transition(to: .awaitingFollowUp)
        OverlayWindowController.shared.mode = .awaitingFollowUp
        self.setOverlayActivity(.waiting)

        // Handle Conversation Mode: auto-listen after response (AC-7, AC-11)
        guard autoListen else { return }

        self.logger.info("Conversation mode enabled, scheduling follow-up")
        Task {
            // Short delay to let the user process the response
            try? await Task.sleep(for: .milliseconds(Int(self.followUpAutoListenDelay * 1000)))

            // Ensure we are still in awaitingFollowUp state (user didn't cancel)
            guard !Task.isCancelled, self.state == .awaitingFollowUp else { return }

            await MainActor.run {
                self.startFollowUp()
            }
        }
    }
    
    // MARK: - Private - Error Handling
    
    private func handleError(_ error: Error) {
        let message = error.localizedDescription
        self.logger.error("Pipeline error: \(message)")
        
        // Cancel any running session task
        self.sessionTask?.cancel()
        self.sessionTask = nil
        self.resetStreamingResponse()
        
        // Stop audio capture to prevent resource leak
        Task {
            await AudioService.shared.cancel()
        }
        
        self.transition(to: .error(message))
        OverlayWindowController.shared.mode = .error(message)
        
        // Auto-recover after delay
        self.autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(self.errorRecoveryDelay))
            guard !Task.isCancelled else { return }
            self.transition(to: .idle)
            self.setOverlayActivity(.none)
            OverlayWindowController.shared.hide(animated: true)
        }
    }

    // MARK: - Private - State Management
    
    private func transition(to newState: PipelineState) {
        let oldState = self.state
        self.state = newState
        
        self.logger.debug("State: \(oldState.description) → \(newState.description)")
        
        // Update status bar
        self.updateStatusBar(for: newState)
    }
    
    private func updateStatusBar(for state: PipelineState) {
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
    private func updateOverlayActivity(from agentActivity: AgentActivity) {
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
        OverlayWindowController.shared.model.setActivity(overlayActivity)
    }

    /// Set the overlay activity directly
    func setOverlayActivity(_ activity: OverlayActivity) {
        OverlayWindowController.shared.model.setActivity(activity)
    }
}
