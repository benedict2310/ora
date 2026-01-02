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
import SwiftData

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
    
    /// Whether auto-listen is enabled
    private var isAutoListenEnabled: Bool {
        // Retrieve directly from settings model
        // Note: In a real app we might inject dependencies, but for now this is fine
        // since AppSettings is SwiftData based but we access the shared model differently
        // or just use UserDefaults for simple settings if AppSettings isn't easily accessible here.
        // Given AppSettings structure, we can't easily access the singleton instance here without context.
        // For O.05, let's assume we can access it or use a simpler approach.
        // Let's use UserDefaults for this setting directly for simplicity if AppSettings is hard to reach,
        // BUT AppSettings is the source of truth.
        // Let's fetch it from the model context if possible, or for now, since AppSettings is a Model,
        // we might need a helper.
        // Actually, let's look at how AppSettings is accessed elsewhere.
        // It seems it's only defined, not used yet.
        // Let's rely on `PersistenceManager.shared` if it exists, or just create a temporary solution.
        // PersistenceManager exists.
        
        // For this implementation, I'll access the persistent store via PersistenceManager
        return self.fetchAutoListenSetting()
    }

    // MARK: - Initialization
    
    private init() {}
    
    private func fetchAutoListenSetting() -> Bool {
        return PersistenceManager.shared.settings.autoListenEnabled
    }
    
    /// Create a test instance (not a singleton)
    static func makeTestInstance() -> SimplePipelineController {
        return SimplePipelineController()
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
            // Initialize conversation for new session
            await self.initializeConversation()
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
        
        // Start listening again (keeping conversation history)
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
        
        // Stop audio
        Task {
            await AudioService.shared.cancel()
        }
        
        self.transition(to: .idle)
        OverlayWindowController.shared.hide(animated: true)
    }
    
    // MARK: - Private - Conversation Management
    
    private func initializeConversation() async {
        // Use a simple conversational prompt for O.01 (no tools, no JSON)
        // This will be replaced with the full system prompt when tools are added in O.02
        let systemPrompt = """
        You are Ora, a helpful voice assistant running locally on macOS.
        
        Current date: \(Self.currentDateString())
        Current time: \(Self.currentTimeString())
        
        Respond naturally and conversationally. Keep responses concise since they will be spoken aloud.
        """
        
        // Start conversation (clears history)
        await ConversationManager.shared.startConversation(systemPrompt: systemPrompt)
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
            
            // AC-13: Empty transcript returns to awaiting follow-up without LLM call
            if self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.logger.info("Empty transcript, transitioning to awaitingFollowUp")
                self.transition(to: .awaitingFollowUp)
                OverlayWindowController.shared.mode = .awaitingFollowUp
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
            
            // Add user message to conversation (context is preserved across turns)
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
        
        // Transition to awaiting follow-up state (AC-14)
        self.transition(to: .awaitingFollowUp)
        OverlayWindowController.shared.mode = .awaitingFollowUp
        
        // Handle Auto-Listen (AC-23)
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
        // Access StatusBarController from AppDelegate since it's not a singleton
        // For now, post a notification that AppDelegate can observe
        // Or we can make StatusBarController accessible
        switch state {
        case .idle, .completed:
            StatusBarController.shared?.setState(.idle)
        case .listening:
            StatusBarController.shared?.setState(.listening)
        case .thinking, .responding, .awaitingFollowUp:
            StatusBarController.shared?.setState(.thinking)
        case .error(let message):
            StatusBarController.shared?.setState(.error(message))
        }
    }
    
    // MARK: - Private - Date Formatting
    
    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: Date())
    }
    
    private static func currentTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: Date())
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
