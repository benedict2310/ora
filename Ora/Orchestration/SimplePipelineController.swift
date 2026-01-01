//
//  SimplePipelineController.swift
//  Ora
//
//  Simple ASR → LLM pipeline coordinator for initial voice-to-text-response flow.
//  This is a simplified first step that enables testing the core pipeline
//  without TTS or tool execution.
//

import Foundation
import AppKit
import os
import Combine

/// Coordinates ASR → LLM pipeline (no tools, no TTS)
///
/// ## State Machine
/// ```
/// idle ──(hotkey press)──► listening ──(hotkey release)──► thinking
///   ▲                          │                              │
///   │                       (cancel)                          ▼
///   │                          │                          responding
///   │                          ▼                              │
///   └─────────────────────── idle ◄───────────────────── completed
///                              ▲                              │
///                              └─────────(auto-dismiss)───────┘
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
    
    /// Delay before auto-dismissing after completion (seconds)
    private let autoDismissDelay: TimeInterval = 5.0
    
    /// Delay before auto-recovering from error (seconds)
    private let errorRecoveryDelay: TimeInterval = 3.0
    
    // MARK: - Initialization
    
    private init() {}
    
    /// Create a test instance (not a singleton)
    static func makeTestInstance() -> SimplePipelineController {
        return SimplePipelineController()
    }
    
    // MARK: - Public API
    
    /// Start listening (hotkey pressed)
    func startListening() {
        guard state.canStartListening else {
            self.logger.warning("Cannot start listening in state: \(self.state.description)")
            return
        }
        
        // Cancel any pending auto-dismiss
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
            await self.runListeningSession()
        }
        
        self.logger.info("Started listening")
    }
    
    /// Stop listening and process (hotkey released)
    func stopListening() {
        guard self.state == .listening else {
            self.logger.warning("Cannot stop listening in state: \(self.state.description)")
            return
        }
        
        self.logger.debug("Stopping listening, triggering ASR finalization")
        
        // Stop audio capture - this will cause the ASR stream to finalize
        // The session task will continue to process the transcript
        Task {
            await AudioService.shared.stop()
        }
    }
    
    /// Cancel current operation and return to idle
    func cancel() {
        self.logger.info("Cancelling current operation from state: \(self.state.description)")
        
        // Cancel all tasks
        self.sessionTask?.cancel()
        self.sessionTask = nil
        self.autoDismissTask?.cancel()
        self.autoDismissTask = nil
        
        // Stop audio
        Task {
            await AudioService.shared.cancel()
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
            
            // AC-11: Empty transcript returns directly to idle without LLM call
            if self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.logger.info("Empty transcript, returning to idle")
                self.transition(to: .idle)
                OverlayWindowController.shared.hide(animated: true)
                return
            }
            
            // Process the transcript with LLM
            await self.processTranscript()
            
        } catch {
            guard !Task.isCancelled else {
                self.logger.debug("Session cancelled during error: \(error.localizedDescription)")
                return
            }
            
            self.handleError(error)
        }
    }
    
    // MARK: - Private - LLM Processing
    
    private func processTranscript() async {
        self.logger.info("Processing transcript: \(self.currentTranscript.prefix(50))...")
        
        self.transition(to: .thinking)
        OverlayWindowController.shared.mode = .thinking
        
        do {
            // Ensure LLM is ready
            try await LLMService.shared.prepare()
            
            // Build system prompt (no tools for now)
            let systemPrompt = SystemPromptBuilder.build(tools: [])
            
            // Start conversation
            await ConversationManager.shared.startConversation(systemPrompt: systemPrompt)
            await ConversationManager.shared.addUserMessage(self.currentTranscript)
            
            let messages = await ConversationManager.shared.getMessagesForLLM()
            
            self.transition(to: .responding)
            OverlayWindowController.shared.mode = .responding
            
            // Stream LLM response
            var fullResponse = ""
            for try await delta in await LLMService.shared.generate(messages: messages, maxTokens: 500) {
                guard !Task.isCancelled else {
                    self.logger.debug("Session cancelled during LLM generation")
                    return
                }
                
                if case .token(let text) = delta {
                    fullResponse += text
                    self.currentResponse = fullResponse
                    OverlayWindowController.shared.model.addAssistantMessage(fullResponse, isPartial: true)
                }
            }
            
            guard !Task.isCancelled else {
                self.logger.debug("Session cancelled after LLM generation")
                return
            }
            
            // Finalize the assistant message
            OverlayWindowController.shared.model.addAssistantMessage(fullResponse, isPartial: false)
            
            // Add to conversation history
            await ConversationManager.shared.addAssistantMessage(fullResponse)
            
            self.handleCompletion()
            
        } catch {
            guard !Task.isCancelled else { return }
            self.handleError(error)
        }
    }
    
    // MARK: - Private - Completion
    
    private func handleCompletion() {
        self.logger.info("Response complete: \(self.currentResponse.prefix(50))...")
        
        self.transition(to: .completed)
        OverlayWindowController.shared.mode = .completed
        
        // Schedule auto-dismiss
        OverlayWindowController.shared.scheduleAutoDismiss()
        
        // Reset to idle after auto-dismiss delay
        self.autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(self.autoDismissDelay))
            guard !Task.isCancelled, self.state == .completed else { return }
            self.transition(to: .idle)
        }
    }
    
    // MARK: - Private - Error Handling
    
    private func handleError(_ error: Error) {
        let message = error.localizedDescription
        self.logger.error("Pipeline error: \(message)")
        
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
        // Access StatusBarController from AppDelegate since it's not a singleton
        // For now, post a notification that AppDelegate can observe
        // Or we can make StatusBarController accessible
        switch state {
        case .idle, .completed:
            StatusBarController.shared?.setState(.idle)
        case .listening:
            StatusBarController.shared?.setState(.listening)
        case .thinking, .responding:
            StatusBarController.shared?.setState(.thinking)
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
