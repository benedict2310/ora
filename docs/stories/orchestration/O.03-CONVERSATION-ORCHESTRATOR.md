# O.02 - Conversation Orchestrator

**Epic:** Orchestration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** O.01 (Agent Loop), A.03 (Transcript Stream), T.02 (Audio Playback)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement the central orchestrator that coordinates the entire voice assistant pipeline:
- Hotkey → Audio capture → ASR transcription
- Transcription → Agent loop reasoning
- Agent response → TTS playback → UI updates

This is the "main loop" that ties all components together.

---

## 2. Architecture

### State Machine

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ConversationOrchestrator                             │
│                            (@MainActor)                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────┐   hotkey     ┌───────────┐   release   ┌──────────┐               │
│   │ idle│ ───press───► │ listening │ ──────────► │ thinking │               │
│   └──┬──┘              └─────┬─────┘             └────┬─────┘               │
│      │                       │                        │                      │
│      │                       │ cancel                 │                      │
│      │◄──────────────────────┘                        │                      │
│      │                                                ▼                      │
│      │                                   ┌────────────────────────┐         │
│      │                                   │   AgentLoop processes  │         │
│      │                                   └────────────┬───────────┘         │
│      │                                                │                      │
│      │                    ┌───────────────────────────┼───────────┐         │
│      │                    ▼                           ▼           ▼         │
│      │            ┌───────────┐             ┌───────────┐  ┌─────────┐     │
│      │            │ proposing │             │responding │  │  error  │     │
│      │            └─────┬─────┘             └─────┬─────┘  └────┬────┘     │
│      │                  │                         │              │          │
│      │         confirm  │  deny                   │              │          │
│      │       ┌──────────┼──────┐                  │              │          │
│      │       ▼          ▼      │                  │              │          │
│      │   ┌────────┐  ┌──────┐  │                  │              │          │
│      │   │executing│  │denied│──┼──────────────►──┴──────────────┘          │
│      │   └────┬───┘  └──────┘  │                  │                         │
│      │        │                 │                  ▼                         │
│      │        ▼                 │            ┌──────────┐                   │
│      │   ┌────────┐             │            │ speaking │                   │
│      │   │follow-up│            │            └────┬─────┘                   │
│      │   └────┬───┘             │                 │                         │
│      │        │                 │                 ▼                         │
│      │        ▼                 │            ┌──────────┐                   │
│      │    speaking ─────────────┴─────────►  │completed │ ─► auto-dismiss   │
│      │                                       └────┬─────┘                   │
│      │                                            │                         │
│      │◄───────────────────────────────────────────┘                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Diagram

```
┌───────────────────────────────────────────────────────────────────┐
│                   ConversationOrchestrator                         │
│                        (@MainActor)                                │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│   Inputs:                      Outputs:                           │
│   ├─ HotkeyManager            ├─ OverlayWindowController          │
│   ├─ AudioService             ├─ StatusBarController              │
│   └─ ASRService               └─ TTSService                       │
│                                                                    │
│   Processing:                                                      │
│   └─ AgentLoop                                                    │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation

### 3.1 Orchestrator State

**File:** `Ora/Orchestration/OrchestratorState.swift`

```swift
//
//  OrchestratorState.swift
//  Ora
//
//  State definitions for the conversation orchestrator
//

import Foundation

/// Current state of the orchestrator
enum OrchestratorState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case proposing(ToolProposal)
    case executing
    case responding
    case speaking
    case completed
    case error(String)
    
    /// Human-readable description
    var description: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .thinking: return "Thinking..."
        case .proposing: return "Confirm action"
        case .executing: return "Executing..."
        case .responding: return "Responding..."
        case .speaking: return "Speaking..."
        case .completed: return "Done"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Tool proposal from agent loop
struct ToolProposal: Equatable, Sendable {
    let id: UUID
    let toolName: String
    let summary: String
    let args: [String: JSONValue]
    let timeout: TimeInterval
    let timestamp: Date
    
    init(toolName: String, summary: String, args: [String: JSONValue], timeout: TimeInterval = 60) {
        self.id = UUID()
        self.toolName = toolName
        self.summary = summary
        self.args = args
        self.timeout = timeout
        self.timestamp = Date()
    }
}

/// Events emitted by the orchestrator
enum OrchestratorEvent: Sendable {
    case stateChanged(OrchestratorState)
    case transcriptPartial(String)
    case transcriptFinal(String)
    case responseToken(String)
    case responseFinal(String)
    case toolProposed(ToolProposal)
    case toolExecuted(String, result: String)
    case error(String)
}
```

### 3.2 Conversation Orchestrator

**File:** `Ora/Orchestration/ConversationOrchestrator.swift`

```swift
//
//  ConversationOrchestrator.swift
//  Ora
//
//  Central coordinator for the voice assistant pipeline
//

import Foundation
import os
import Combine

/// Coordinates all components for a conversation turn
@MainActor
final class ConversationOrchestrator: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = ConversationOrchestrator()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "Orchestrator")
    
    @Published private(set) var state: OrchestratorState = .idle
    @Published private(set) var currentTranscript: String = ""
    @Published private(set) var currentResponse: String = ""
    
    private let agentLoop = AgentLoop()
    private var currentSessionID: UUID?
    private var asrTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var confirmationTimeoutTask: Task<Void, Never>?
    
    private var pendingProposal: ToolProposal?
    
    /// Event stream for external observers
    private let eventSubject = PassthroughSubject<OrchestratorEvent, Never>()
    var events: AnyPublisher<OrchestratorEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    private init() {
        setupNotifications()
    }
    
    // MARK: - Public API
    
    /// Start listening (hotkey pressed)
    func startListening() {
        guard state == .idle || state == .completed else {
            logger.warning("Cannot start listening in state: \(self.state.description)")
            return
        }
        
        currentSessionID = UUID()
        currentTranscript = ""
        currentResponse = ""
        
        transition(to: .listening)
        
        // Show overlay
        OverlayWindowController.shared.mode = .listening
        OverlayWindowController.shared.show()
        
        // Start audio capture and ASR
        startASR()
        
        logger.info("Started listening, session: \(self.currentSessionID?.uuidString ?? "nil")")
    }
    
    /// Stop listening and process (hotkey released)
    func stopListening() {
        guard state == .listening else {
            logger.warning("Cannot stop listening in state: \(self.state.description)")
            return
        }
        
        // Stop ASR
        asrTask?.cancel()
        asrTask = nil
        
        // Process the transcript
        if !currentTranscript.isEmpty {
            transition(to: .thinking)
            OverlayWindowController.shared.mode = .thinking
            processTranscript()
        } else {
            // Nothing said, go back to idle
            transition(to: .idle)
            OverlayWindowController.shared.hide()
        }
    }
    
    /// Cancel current operation
    func cancel() {
        logger.info("Cancelling current operation")
        
        asrTask?.cancel()
        processingTask?.cancel()
        ttsTask?.cancel()
        confirmationTimeoutTask?.cancel()
        
        asrTask = nil
        processingTask = nil
        ttsTask = nil
        confirmationTimeoutTask = nil
        
        pendingProposal = nil
        
        // Stop any playing audio
        Task {
            await TTSService.shared.stop()
            await AudioService.shared.stop()
        }
        
        transition(to: .idle)
        OverlayWindowController.shared.hide(animated: true)
    }
    
    /// Confirm a pending tool proposal
    func confirmProposal() {
        guard case .proposing(let proposal) = state,
              pendingProposal?.id == proposal.id else {
            logger.warning("No pending proposal to confirm")
            return
        }
        
        logger.info("Proposal confirmed: \(proposal.toolName)")
        
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        
        executeProposal(proposal)
    }
    
    /// Deny a pending tool proposal
    func denyProposal() {
        guard case .proposing = state else {
            logger.warning("No pending proposal to deny")
            return
        }
        
        logger.info("Proposal denied")
        
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        pendingProposal = nil
        
        // Generate a polite acknowledgment
        let response = "Okay, I won't do that."
        currentResponse = response
        eventSubject.send(.responseFinal(response))
        
        speak(response)
    }
    
    // MARK: - Private - ASR
    
    private func startASR() {
        asrTask = Task {
            do {
                try await AudioService.shared.start()
                
                let asrStream = await ASRService.shared.transcribe(
                    frames: AudioService.shared.frames
                )
                
                for try await event in asrStream {
                    guard !Task.isCancelled else { break }
                    
                    switch event {
                    case .partial(let text, _):
                        currentTranscript = text
                        eventSubject.send(.transcriptPartial(text))
                        OverlayWindowController.shared.model.addUserMessage(text, isPartial: true)
                        
                    case .final(let text):
                        currentTranscript = text
                        eventSubject.send(.transcriptFinal(text))
                        OverlayWindowController.shared.model.addUserMessage(text, isPartial: false)
                        
                    case .endOfSpeech:
                        // Auto-stop on end of speech detection (optional)
                        break
                    }
                }
            } catch {
                logger.error("ASR error: \(error.localizedDescription)")
                handleError(error)
            }
            
            await AudioService.shared.stop()
        }
    }
    
    // MARK: - Private - Processing
    
    private func processTranscript() {
        processingTask = Task {
            do {
                let result = try await agentLoop.process(
                    userText: currentTranscript,
                    sessionID: currentSessionID
                )
                
                guard !Task.isCancelled else { return }
                
                switch result {
                case .response(let text):
                    handleResponse(text)
                    
                case .proposal(let summary, let tool, let args):
                    handleProposal(summary: summary, tool: tool, args: args)
                    
                case .error(let message):
                    handleError(OrchestratorError.agentError(message))
                }
                
            } catch {
                handleError(error)
            }
        }
    }
    
    private func handleResponse(_ text: String) {
        logger.info("Got response: \(text.prefix(50))...")
        
        transition(to: .responding)
        OverlayWindowController.shared.mode = .responding
        
        currentResponse = text
        eventSubject.send(.responseFinal(text))
        
        OverlayWindowController.shared.model.addAssistantMessage(text, isPartial: false)
        
        speak(text)
    }
    
    private func handleProposal(summary: String, tool: String, args: [String: JSONValue]) {
        logger.info("Got proposal: \(tool) - \(summary)")
        
        let proposal = ToolProposal(toolName: tool, summary: summary, args: args)
        pendingProposal = proposal
        
        transition(to: .proposing(proposal))
        OverlayWindowController.shared.mode = .proposing(
            ToolProposal(toolName: tool, summary: summary, args: args)
        )
        
        eventSubject.send(.toolProposed(proposal))
        
        // Start timeout
        startConfirmationTimeout(proposal)
    }
    
    private func startConfirmationTimeout(_ proposal: ToolProposal) {
        confirmationTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(proposal.timeout))
            
            guard !Task.isCancelled,
                  case .proposing(let current) = state,
                  current.id == proposal.id else {
                return
            }
            
            logger.info("Proposal timed out: \(proposal.toolName)")
            
            pendingProposal = nil
            let response = "The request timed out. Let me know if you'd like to try again."
            currentResponse = response
            
            transition(to: .responding)
            speak(response)
        }
    }
    
    private func executeProposal(_ proposal: ToolProposal) {
        transition(to: .executing)
        OverlayWindowController.shared.mode = .executing
        
        processingTask = Task {
            do {
                // Execute the confirmed tool
                let result = try await agentLoop.executeConfirmedTool(
                    tool: proposal.toolName,
                    args: proposal.args
                )
                
                guard !Task.isCancelled else { return }
                
                eventSubject.send(.toolExecuted(proposal.toolName, result: result.humanSummary))
                
                // Generate follow-up response
                let followUp = try await agentLoop.generateFollowUp()
                
                pendingProposal = nil
                handleResponse(followUp)
                
            } catch {
                pendingProposal = nil
                handleError(error)
            }
        }
    }
    
    // MARK: - Private - TTS
    
    private func speak(_ text: String) {
        transition(to: .speaking)
        OverlayWindowController.shared.mode = .responding
        
        ttsTask = Task {
            do {
                let audioStream = await TTSService.shared.speak(text)
                
                for try await chunk in audioStream {
                    guard !Task.isCancelled else { break }
                    await AudioPlayback.shared.enqueue(chunk)
                }
                
                // Wait for playback to finish
                await AudioPlayback.shared.waitForCompletion()
                
                guard !Task.isCancelled else { return }
                
                handleCompletion()
                
            } catch {
                logger.error("TTS error: \(error.localizedDescription)")
                // Still complete even if TTS fails - text is shown
                handleCompletion()
            }
        }
    }
    
    // MARK: - Private - Completion
    
    private func handleCompletion() {
        transition(to: .completed)
        OverlayWindowController.shared.mode = .completed
        
        // Schedule auto-dismiss
        OverlayWindowController.shared.scheduleAutoDismiss()
        
        // After auto-dismiss delay, reset to idle
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, state == .completed else { return }
            transition(to: .idle)
        }
    }
    
    // MARK: - Private - Error Handling
    
    private func handleError(_ error: Error) {
        logger.error("Orchestrator error: \(error.localizedDescription)")
        
        let message = error.localizedDescription
        transition(to: .error(message))
        OverlayWindowController.shared.mode = .error(message)
        
        eventSubject.send(.error(message))
        
        // Auto-recover after delay
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            transition(to: .idle)
            OverlayWindowController.shared.hide()
        }
    }
    
    // MARK: - Private - State Management
    
    private func transition(to newState: OrchestratorState) {
        let oldState = state
        state = newState
        
        logger.debug("State: \(oldState.description) → \(newState.description)")
        eventSubject.send(.stateChanged(newState))
        
        // Update status bar
        switch newState {
        case .idle:
            StatusBarController.shared?.setState(.idle)
        case .listening:
            StatusBarController.shared?.setState(.listening)
        case .thinking, .proposing, .executing, .responding:
            StatusBarController.shared?.setState(.thinking)
        case .speaking:
            StatusBarController.shared?.setState(.speaking)
        case .completed:
            StatusBarController.shared?.setState(.idle)
        case .error:
            StatusBarController.shared?.setState(.error)
        }
    }
    
    // MARK: - Private - Notifications
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .proposalConfirmed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.confirmProposal()
        }
        
        NotificationCenter.default.addObserver(
            forName: .proposalDenied,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.denyProposal()
        }
    }
}

// MARK: - Errors

enum OrchestratorError: LocalizedError {
    case agentError(String)
    case timeout
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .agentError(let message): return message
        case .timeout: return "Request timed out"
        case .cancelled: return "Request cancelled"
        }
    }
}
```

### 3.3 Integration with Hotkey

**Update:** `Ora/AppDelegate.swift`

```swift
// In hotkey handler setup:

private func setupHotkey() {
    HotkeyManager.shared.onPress = { [weak self] in
        Task { @MainActor in
            ConversationOrchestrator.shared.startListening()
        }
    }
    
    HotkeyManager.shared.onRelease = { [weak self] in
        Task { @MainActor in
            ConversationOrchestrator.shared.stopListening()
        }
    }
}
```

---

## 4. Directory Structure

```
Ora/
└── Orchestration/
    ├── OrchestratorState.swift
    ├── ConversationOrchestrator.swift
    └── AgentLoop.swift  (from O.01)
```

---

## 5. Acceptance Criteria

### Pipeline Flow

- [ ] **AC-1:** Hotkey press starts audio capture and ASR
- [ ] **AC-2:** Partial transcripts stream to overlay UI
- [ ] **AC-3:** Hotkey release triggers agent processing
- [ ] **AC-4:** Agent response streams to UI
- [ ] **AC-5:** TTS plays response audio
- [ ] **AC-6:** Overlay auto-dismisses after completion

### State Management

- [ ] **AC-7:** State transitions correctly through all phases
- [ ] **AC-8:** State published for UI binding
- [ ] **AC-9:** Events emitted for external observers
- [ ] **AC-10:** Status bar updates with state

### Cancellation

- [ ] **AC-11:** User can cancel at any point
- [ ] **AC-12:** Cancellation stops all active tasks
- [ ] **AC-13:** Cancellation cleans up state properly

### Error Handling

- [ ] **AC-14:** Errors display in overlay
- [ ] **AC-15:** Auto-recovery after error display
- [ ] **AC-16:** Errors logged for debugging

---

## 6. Test Cases

```swift
// ConversationOrchestratorTests.swift

import XCTest
@testable import Ora

@MainActor
final class ConversationOrchestratorTests: XCTestCase {
    
    // TC-1: Initial state is idle
    func test_initialState_isIdle() {
        let orchestrator = ConversationOrchestrator.shared
        XCTAssertEqual(orchestrator.state, .idle)
    }
    
    // TC-2: Start listening transitions state
    func test_startListening_transitionsToListening() async {
        let orchestrator = ConversationOrchestrator.shared
        orchestrator.startListening()
        XCTAssertEqual(orchestrator.state, .listening)
        orchestrator.cancel()
    }
    
    // TC-3: Cancel returns to idle
    func test_cancel_returnsToIdle() async {
        let orchestrator = ConversationOrchestrator.shared
        orchestrator.startListening()
        orchestrator.cancel()
        XCTAssertEqual(orchestrator.state, .idle)
    }
    
    // TC-4: Cannot start listening when not idle
    func test_startListening_whenNotIdle_doesNotTransition() async {
        let orchestrator = ConversationOrchestrator.shared
        orchestrator.startListening()
        let state = orchestrator.state
        orchestrator.startListening() // Try again
        XCTAssertEqual(orchestrator.state, state) // Should not change
        orchestrator.cancel()
    }
}
```

---

## 7. Implementation Checklist

- [ ] Create `OrchestratorState.swift`
- [ ] Create `ConversationOrchestrator.swift`
- [ ] Integrate with HotkeyManager
- [ ] Integrate with AudioService
- [ ] Integrate with ASRService
- [ ] Integrate with AgentLoop
- [ ] Integrate with TTSService
- [ ] Integrate with OverlayWindowController
- [ ] Integrate with StatusBarController
- [ ] Test full pipeline flow
- [ ] Test cancellation handling
- [ ] Test error recovery
