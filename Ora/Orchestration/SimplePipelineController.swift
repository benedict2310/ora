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
    
    /// The agent loop for processing requests
    private let agentLoop: AgentLoop
    
    /// Observers for proposal confirmation/denial
    /// Using nonisolated(unsafe) since these are only accessed from MainActor
    /// and this is a singleton that lives for the app's lifetime
    nonisolated(unsafe) private var proposalConfirmObserver: NSObjectProtocol?
    nonisolated(unsafe) private var proposalDenyObserver: NSObjectProtocol?
    
    /// Delay before auto-recovering from error (seconds)
    private let errorRecoveryDelay: TimeInterval = 3.0
    
    /// Whether auto-listen is enabled
    private var isAutoListenEnabled: Bool {
        return self.fetchAutoListenSetting()
    }

    /// Whether there is an active conversation session
    var isSessionActive: Bool {
        switch self.state {
        case .idle, .completed:
            return false
        default:
            return true
        }
    }

    // MARK: - Initialization
    
    private init(agentLoop: AgentLoop = AgentLoop()) {
        self.agentLoop = agentLoop
        self.setupProposalObservers()
    }
    
    private func fetchAutoListenSetting() -> Bool {
        return PersistenceManager.shared.settings.autoListenEnabled
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
    }
    
    deinit {
        if let observer = proposalConfirmObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = proposalDenyObserver {
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
        
        // Reset overlay for new session
        OverlayWindowController.shared.model.reset()
        
        self.transition(to: .listening)
        
        // Show overlay in listening mode
        OverlayWindowController.shared.mode = .listening
        OverlayWindowController.shared.show()
        
        // Start the session task
        self.sessionTask = Task {
            // Initialize agent session (with tool definitions)
            await self.agentLoop.startSession()
            await self.runListeningSession()
        }
        
        self.logger.info("Started listening")
    }
    
    /// Submit transcript manually (Enter key)
    func submitTranscript() {
        guard self.state == .listening else {
            self.logger.warning("Cannot submit transcript in state: \(self.state.description)")
            return
        }
        
        self.logger.debug("Submitting transcript")
        
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
    
    /// Cancel current operation and return to idle
    func cancel() {
        self.logger.info("Cancelling current operation from state: \(self.state.description)")

        // Cancel all tasks
        self.sessionTask?.cancel()
        self.sessionTask = nil
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        self.ttsTask?.cancel()
        self.ttsTask = nil
        self.confirmationTask?.cancel()
        self.confirmationTask = nil

        // Stop audio capture and TTS playback
        Task {
            await TTSService.shared.stop()
            await AudioPlaybackService.shared.stop()
            await AudioService.shared.cancel()
            await self.agentLoop.endSession()
            await self.agentLoop.clearPendingProposal()
        }

        self.transition(to: .idle)
        OverlayWindowController.shared.hide(animated: true)
    }
    
    // MARK: - Private - Session Management
    
    private func runListeningSession() async {
        do {
            // Reset ASR state for new session
            await ASRService.shared.reset()
            
            // Start audio capture
            let audioStream = try await AudioService.shared.start()
            
            // Start transcription
            let asrStream = await ASRService.shared.transcribe(frames: audioStream)
            
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
        
        self.transition(to: .thinking)
        OverlayWindowController.shared.mode = .thinking
        
        do {
            // Ensure LLM is ready
            try await LLMService.shared.prepare()
            
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
            self.speakResponse(followUpText)
            
        } catch {
            guard !Task.isCancelled else { return }
            
            self.logger.error("Tool execution failed: \(error.localizedDescription)")
            self.handleAgentError("I couldn't complete that action: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private - TTS
    
    private func speakResponse(_ text: String) {
        self.transition(to: .speaking)

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

        // Transition to awaiting follow-up state
        self.transition(to: .awaitingFollowUp)
        OverlayWindowController.shared.mode = .awaitingFollowUp

        // Handle Auto-Listen if enabled
        if self.isAutoListenEnabled {
            self.logger.info("Auto-listen enabled, scheduling follow-up")
            Task {
                // Short delay to let the user process the response
                try? await Task.sleep(for: .milliseconds(500))

                // Ensure we are still in awaitingFollowUp state (user didn't cancel)
                guard !Task.isCancelled, self.state == .awaitingFollowUp else { return }

                await MainActor.run {
                    self.startFollowUp()
                }
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
        switch state {
        case .idle, .completed:
            StatusBarController.shared?.setState(.idle)
        case .listening:
            StatusBarController.shared?.setState(.listening)
        case .thinking, .responding, .awaitingFollowUp, .executing:
            StatusBarController.shared?.setState(.thinking)
        case .speaking:
            StatusBarController.shared?.setState(.speaking)
        case .error(let message):
            StatusBarController.shared?.setState(.error(message))
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
