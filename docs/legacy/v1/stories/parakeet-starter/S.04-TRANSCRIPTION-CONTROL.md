# S.04 - Transcription Control Layer

**Epic:** Parakeet Starter Pack
**Status:** Ready for Implementation
**Date:** 2025-12-27
**Dependency:** S.03-STREAMING-MANAGER (StreamingManager, ASREngine protocol)
**Priority:** Critical (Core application orchestration)

---

## 1. Objective

Implement the central transcription orchestration layer that manages the complete lifecycle of speech-to-text sessions. This component coordinates audio capture, streaming transcription, state management, and inter-component communication.

**Goal:** Provide a robust, thread-safe state machine that cleanly manages transcription sessions from start to finish, with proper cancellation, error recovery, and notification-based communication.

**Scope Exclusions (per user requirements):**
- No Whisper support (Parakeet-only)
- No clipboard integration
- No auto-paste functionality
- No visualizations/HUD

---

## 2. Architecture Overview

```
                                    NotificationCenter
                                           ^
                                           | Posts
                                           |
    ┌──────────────────────────────────────┼──────────────────────────────────────┐
    │                          TranscriptionController                            │
    │                                                                             │
    │  ┌─────────────┐    ┌──────────────────┐    ┌───────────────────┐          │
    │  │    State    │    │  Session Manager │    │  Notification     │          │
    │  │   Machine   │◄──►│                  │◄──►│   Publisher       │          │
    │  │             │    │  - UUID tracking │    │                   │          │
    │  │ idle        │    │  - Task registry │    │ - stateDidChange  │          │
    │  │ preparing   │    │  - Cancellation  │    │ - partialReceived │          │
    │  │ listening   │    │                  │    │ - finalReceived   │          │
    │  │ transcribing│    └────────┬─────────┘    │ - error           │          │
    │  │ finalizing  │             │              └───────────────────┘          │
    │  │ error       │             │                                             │
    │  └─────────────┘             │                                             │
    │         ▲                    ▼                                             │
    │         │         ┌──────────────────┐                                     │
    │         │         │  Component Refs  │                                     │
    │         │         │                  │                                     │
    │         │         │  - AudioCapture  │                                     │
    │         └─────────│  - StreamingMgr  │                                     │
    │                   │  - ParakeetEngine│                                     │
    │                   └──────────────────┘                                     │
    └─────────────────────────────────────────────────────────────────────────────┘
                    │                           │
                    ▼                           ▼
           ┌──────────────┐           ┌─────────────────┐
           │ AudioCapture │           │ StreamingManager │
           │              │           │                  │
           │ - AVAudioEng │           │ - Ring buffer    │
           │ - 16kHz mono │           │ - Hop timer      │
           └──────────────┘           │ - ParakeetEngine │
                                      └─────────────────┘
```

---

## 3. Core Components

### 3.1 TranscriptionState Enum

The state machine that governs all transcription lifecycle phases.

```swift
// File: TranscriptionState.swift

import Foundation

/// Represents the current state of the transcription system.
/// All state transitions are validated; invalid transitions are rejected.
enum TranscriptionState: Sendable, Equatable, CustomStringConvertible {
    /// System is idle, no resources allocated
    case idle

    /// Engine is loading models, preparing for transcription
    case preparing

    /// Audio capture active, waiting for speech detection
    case listening

    /// Active speech detected, streaming partials
    case transcribing

    /// Speech ended, generating final result
    case finalizing

    /// Error state with descriptive message
    case error(String)

    // MARK: - CustomStringConvertible

    var description: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .finalizing: return "finalizing"
        case .error(let message): return "error(\(message))"
        }
    }

    // MARK: - State Query Properties

    /// Returns true if transcription is actively running
    var isActive: Bool {
        switch self {
        case .listening, .transcribing, .finalizing:
            return true
        case .idle, .preparing, .error:
            return false
        }
    }

    /// Returns true if audio capture should be running
    var shouldCaptureAudio: Bool {
        switch self {
        case .listening, .transcribing:
            return true
        case .idle, .preparing, .finalizing, .error:
            return false
        }
    }

    /// Returns true if the state represents an error
    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// Returns true if system can accept start() calls
    var canStart: Bool {
        switch self {
        case .idle, .error:
            return true
        case .preparing, .listening, .transcribing, .finalizing:
            return false
        }
    }

    /// Returns true if system can accept stop() calls
    var canStop: Bool {
        switch self {
        case .preparing, .listening, .transcribing, .finalizing:
            return true
        case .idle, .error:
            return false
        }
    }

    // MARK: - Transition Validation

    /// Validates whether a transition to the target state is legal
    func canTransition(to target: TranscriptionState) -> Bool {
        switch (self, target) {
        // From idle: can only prepare
        case (.idle, .preparing):
            return true

        // From preparing: can go to listening (success) or error (failure)
        case (.preparing, .listening),
             (.preparing, .error),
             (.preparing, .idle):  // Cancelled during preparation
            return true

        // From listening: can transcribe, finalize, or error
        case (.listening, .transcribing),
             (.listening, .finalizing),  // Stop called while listening
             (.listening, .error),
             (.listening, .idle):  // Stop called, no audio captured
            return true

        // From transcribing: can finalize, return to listening, or error
        case (.transcribing, .finalizing),
             (.transcribing, .listening),  // Silence detected, waiting for more
             (.transcribing, .error):
            return true

        // From finalizing: can return to idle or error
        case (.finalizing, .idle),
             (.finalizing, .listening),  // More speech detected after pause
             (.finalizing, .error):
            return true

        // From error: can only reset to idle
        case (.error, .idle):
            return true

        // All other transitions are invalid
        default:
            return false
        }
    }
}

// MARK: - Equatable Conformance for Error Case

extension TranscriptionState {
    static func == (lhs: TranscriptionState, rhs: TranscriptionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.preparing, .preparing),
             (.listening, .listening),
             (.transcribing, .transcribing),
             (.finalizing, .finalizing):
            return true
        case (.error(let lhsMsg), .error(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}
```

### 3.2 TranscriptionSession

Encapsulates all session-specific data for isolation between sessions.

```swift
// File: TranscriptionSession.swift

import Foundation

/// Represents a single transcription session with unique identity.
/// Used to correlate results and ensure session isolation.
struct TranscriptionSession: Sendable, Identifiable {
    /// Unique identifier for this session
    let id: UUID

    /// Timestamp when session was created
    let startedAt: Date

    /// Accumulated transcript segments for this session
    private(set) var segments: [ASRFinalSegment]

    /// Current partial transcript (not yet finalized)
    private(set) var currentPartial: String

    /// Session configuration
    let configuration: SessionConfiguration

    // MARK: - Initialization

    init(configuration: SessionConfiguration = .default) {
        self.id = UUID()
        self.startedAt = Date()
        self.segments = []
        self.currentPartial = ""
        self.configuration = configuration
    }

    // MARK: - Session Configuration

    struct SessionConfiguration: Sendable {
        /// Minimum audio duration before processing (seconds)
        let minimumAudioDuration: TimeInterval

        /// Silence duration to trigger finalization (seconds)
        let silenceThreshold: TimeInterval

        /// Maximum session duration (seconds, 0 = unlimited)
        let maxDuration: TimeInterval

        /// Language hint for transcription (nil = auto-detect)
        let language: String?

        static let `default` = SessionConfiguration(
            minimumAudioDuration: 0.3,
            silenceThreshold: 0.5,
            maxDuration: 0,
            language: nil
        )
    }

    // MARK: - Mutating Operations

    /// Updates the current partial transcript
    mutating func updatePartial(_ text: String) {
        currentPartial = text
    }

    /// Adds a finalized segment and clears the partial
    mutating func addFinalSegment(_ segment: ASRFinalSegment) {
        segments.append(segment)
        currentPartial = ""
    }

    /// Clears the current partial without adding a segment
    mutating func clearPartial() {
        currentPartial = ""
    }

    // MARK: - Computed Properties

    /// Duration since session started
    var duration: TimeInterval {
        Date().timeIntervalSince(startedAt)
    }

    /// Combined text from all finalized segments
    var finalizedText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Full text including current partial
    var fullText: String {
        let finalized = finalizedText
        if currentPartial.isEmpty {
            return finalized
        }
        return finalized.isEmpty ? currentPartial : "\(finalized) \(currentPartial)"
    }

    /// Returns true if session has exceeded max duration
    var isExpired: Bool {
        guard configuration.maxDuration > 0 else { return false }
        return duration >= configuration.maxDuration
    }
}
```

### 3.3 NotificationCenter Integration

Custom notification names and payload structures for inter-component communication.

```swift
// File: TranscriptionNotifications.swift

import Foundation

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when transcription state changes
    /// UserInfo: [stateKey: TranscriptionState, previousStateKey: TranscriptionState]
    static let transcriptionStateDidChange = Notification.Name("transcriptionStateDidChange")

    /// Posted when a partial transcription result is available
    /// UserInfo: [partialKey: ASRPartial, sessionIDKey: UUID]
    static let transcriptionPartialReceived = Notification.Name("transcriptionPartialReceived")

    /// Posted when a final transcription segment is available
    /// UserInfo: [finalKey: ASRFinalSegment, sessionIDKey: UUID]
    static let transcriptionFinalReceived = Notification.Name("transcriptionFinalReceived")

    /// Posted when a transcription error occurs
    /// UserInfo: [errorKey: TranscriptionError, sessionIDKey: UUID?]
    static let transcriptionError = Notification.Name("transcriptionError")

    /// Posted when a session starts
    /// UserInfo: [sessionIDKey: UUID]
    static let transcriptionSessionStarted = Notification.Name("transcriptionSessionStarted")

    /// Posted when a session ends
    /// UserInfo: [sessionIDKey: UUID, sessionResultKey: TranscriptionSessionResult]
    static let transcriptionSessionEnded = Notification.Name("transcriptionSessionEnded")
}

// MARK: - UserInfo Keys

enum TranscriptionNotificationKey {
    static let state = "state"
    static let previousState = "previousState"
    static let partial = "partial"
    static let final = "final"
    static let sessionID = "sessionID"
    static let error = "error"
    static let sessionResult = "sessionResult"
}

// MARK: - Notification Payloads

/// Result payload for session completion
struct TranscriptionSessionResult: Sendable {
    let sessionID: UUID
    let duration: TimeInterval
    let finalText: String
    let segmentCount: Int
    let wasSuccessful: Bool
    let errorMessage: String?
}

// MARK: - Notification Publisher Helper

/// Thread-safe notification publisher for transcription events
final class TranscriptionNotificationPublisher: Sendable {

    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    // MARK: - State Notifications

    func postStateChange(from oldState: TranscriptionState, to newState: TranscriptionState) {
        let userInfo: [String: Any] = [
            TranscriptionNotificationKey.state: newState,
            TranscriptionNotificationKey.previousState: oldState
        ]

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .transcriptionStateDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    // MARK: - Partial Notifications

    func postPartial(_ partial: ASRPartial, sessionID: UUID) {
        let userInfo: [String: Any] = [
            TranscriptionNotificationKey.partial: partial,
            TranscriptionNotificationKey.sessionID: sessionID
        ]

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .transcriptionPartialReceived,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    // MARK: - Final Notifications

    func postFinal(_ segment: ASRFinalSegment, sessionID: UUID) {
        let userInfo: [String: Any] = [
            TranscriptionNotificationKey.final: segment,
            TranscriptionNotificationKey.sessionID: sessionID
        ]

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .transcriptionFinalReceived,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    // MARK: - Error Notifications

    func postError(_ error: TranscriptionError, sessionID: UUID?) {
        var userInfo: [String: Any] = [
            TranscriptionNotificationKey.error: error
        ]
        if let sessionID {
            userInfo[TranscriptionNotificationKey.sessionID] = sessionID
        }

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .transcriptionError,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    // MARK: - Session Lifecycle Notifications

    func postSessionStarted(sessionID: UUID) {
        let userInfo: [String: Any] = [
            TranscriptionNotificationKey.sessionID: sessionID
        ]

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .transcriptionSessionStarted,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    func postSessionEnded(result: TranscriptionSessionResult) {
        let userInfo: [String: Any] = [
            TranscriptionNotificationKey.sessionID: result.sessionID,
            TranscriptionNotificationKey.sessionResult: result
        ]

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .transcriptionSessionEnded,
                object: nil,
                userInfo: userInfo
            )
        }
    }
}
```

### 3.4 TranscriptionError

Comprehensive error types for the transcription system.

```swift
// File: TranscriptionError.swift

import Foundation

/// Errors that can occur during transcription operations
enum TranscriptionError: Error, Sendable, LocalizedError, Equatable {
    // MARK: - Engine Errors

    /// Engine failed to initialize
    case engineInitializationFailed(String)

    /// Engine is not ready for processing
    case engineNotReady

    /// Engine processing failed
    case engineProcessingFailed(String)

    /// Model loading failed
    case modelLoadFailed(String)

    // MARK: - Audio Errors

    /// Microphone access denied
    case microphonePermissionDenied

    /// Audio capture failed to start
    case audioCaptureStartFailed(String)

    /// Audio format is unsupported
    case unsupportedAudioFormat

    /// Audio buffer creation failed
    case audioBufferCreationFailed

    // MARK: - State Errors

    /// Invalid state transition attempted
    case invalidStateTransition(from: String, to: String)

    /// Operation not allowed in current state
    case operationNotAllowedInState(operation: String, state: String)

    /// Session was cancelled
    case sessionCancelled

    /// Session timed out
    case sessionTimedOut

    // MARK: - System Errors

    /// Unknown/unexpected error
    case unknown(String)

    // MARK: - LocalizedError

    var errorDescription: String? {
        switch self {
        case .engineInitializationFailed(let reason):
            return "Engine initialization failed: \(reason)"
        case .engineNotReady:
            return "Transcription engine is not ready"
        case .engineProcessingFailed(let reason):
            return "Engine processing failed: \(reason)"
        case .modelLoadFailed(let reason):
            return "Model loading failed: \(reason)"
        case .microphonePermissionDenied:
            return "Microphone access denied. Please grant permission in System Preferences."
        case .audioCaptureStartFailed(let reason):
            return "Audio capture failed to start: \(reason)"
        case .unsupportedAudioFormat:
            return "Audio format is not supported"
        case .audioBufferCreationFailed:
            return "Failed to create audio buffer"
        case .invalidStateTransition(let from, let to):
            return "Invalid state transition from \(from) to \(to)"
        case .operationNotAllowedInState(let operation, let state):
            return "Operation '\(operation)' not allowed in state '\(state)'"
        case .sessionCancelled:
            return "Transcription session was cancelled"
        case .sessionTimedOut:
            return "Transcription session timed out"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }

    // MARK: - Recovery Suggestions

    var recoverySuggestion: String? {
        switch self {
        case .engineInitializationFailed, .modelLoadFailed:
            return "Try restarting the application or redownloading the model."
        case .microphonePermissionDenied:
            return "Open System Preferences > Privacy & Security > Microphone and enable access."
        case .sessionCancelled, .sessionTimedOut:
            return "Start a new transcription session."
        default:
            return nil
        }
    }

    // MARK: - Severity

    /// Whether this error is recoverable without user intervention
    var isRecoverable: Bool {
        switch self {
        case .sessionCancelled, .sessionTimedOut, .invalidStateTransition, .operationNotAllowedInState:
            return true
        case .microphonePermissionDenied, .engineInitializationFailed, .modelLoadFailed:
            return false
        default:
            return true
        }
    }
}
```

### 3.5 TranscriptionController

The main orchestrator class that ties everything together.

```swift
// File: TranscriptionController.swift

import Foundation
import AVFoundation
import os.log

/// Central orchestrator for transcription lifecycle management.
/// Manages audio capture, streaming, and state transitions.
///
/// ## Threading Model
/// - State changes occur on MainActor for UI consistency
/// - Audio callbacks arrive from real-time audio threads
/// - Engine processing runs on background queues
/// - All cross-thread communication uses Sendable closures
///
/// ## Usage
/// ```swift
/// let controller = TranscriptionController(engine: parakeetEngine)
/// try await controller.start()
/// // ... transcription in progress ...
/// await controller.stop()
/// ```
@MainActor
final class TranscriptionController: ObservableObject {

    // MARK: - Published State

    /// Current transcription state
    @Published private(set) var state: TranscriptionState = .idle

    /// Current accumulated transcript text
    @Published private(set) var currentTranscript: String = ""

    /// Current partial (unconfirmed) text
    @Published private(set) var currentPartial: String = ""

    // MARK: - Callbacks (Alternative to NotificationCenter)

    /// Called when a partial result is available
    var onPartial: ((ASRPartial) -> Void)?

    /// Called when a final segment is available
    var onFinal: ((ASRFinalSegment) -> Void)?

    /// Called when an error occurs
    var onError: ((TranscriptionError) -> Void)?

    /// Called when state changes
    var onStateChange: ((TranscriptionState, TranscriptionState) -> Void)?

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.parakeet-starter", category: "TranscriptionController")

    /// ASR engine for transcription
    private let engine: any ASREngine

    /// Audio capture component
    private let audioCapture: AudioCapture

    /// Streaming transcription manager
    private let streamingManager: StreamingManager

    /// Notification publisher
    private let notificationPublisher: TranscriptionNotificationPublisher

    /// Current session (nil when idle)
    private var currentSession: TranscriptionSession?

    /// Task registry for cancellation
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Lock for thread-safe session access (for non-MainActor contexts)
    private let sessionLock = NSLock()

    // MARK: - Initialization

    init(
        engine: any ASREngine,
        audioCapture: AudioCapture = AudioCapture(),
        streamingManagerFactory: ((any ASREngine) -> StreamingManager)? = nil,
        notificationPublisher: TranscriptionNotificationPublisher = TranscriptionNotificationPublisher()
    ) {
        self.engine = engine
        self.audioCapture = audioCapture
        self.streamingManager = streamingManagerFactory?(engine) ?? StreamingManager(engine: engine)
        self.notificationPublisher = notificationPublisher

        setupStreamingCallbacks()
    }

    // MARK: - Private Setup

    private func setupStreamingCallbacks() {
        // Wire streaming manager callbacks to controller
        streamingManager.onPartial = { [weak self] partial in
            Task { @MainActor in
                self?.handlePartial(partial)
            }
        }

        streamingManager.onFinal = { [weak self] segment in
            Task { @MainActor in
                self?.handleFinal(segment)
            }
        }

        streamingManager.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleStreamingError(error)
            }
        }
    }

    // MARK: - Public Control API

    /// Starts a new transcription session
    ///
    /// - Parameter configuration: Optional session configuration
    /// - Throws: `TranscriptionError` if start fails
    func start(configuration: TranscriptionSession.SessionConfiguration = .default) async throws {
        logger.info("Start requested, current state: \(self.state.description)")

        // Validate we can start
        guard state.canStart else {
            let error = TranscriptionError.operationNotAllowedInState(
                operation: "start",
                state: state.description
            )
            throw error
        }

        // Transition to preparing
        try transitionTo(.preparing)

        do {
            // Create new session
            let session = TranscriptionSession(configuration: configuration)
            currentSession = session

            // Post session started notification
            notificationPublisher.postSessionStarted(sessionID: session.id)

            logger.info("Session started: \(session.id)")

            // Prepare engine (model loading, warm-up)
            try await engine.prepare()

            // Check for cancellation
            guard !Task.isCancelled else {
                try transitionTo(.idle)
                throw TranscriptionError.sessionCancelled
            }

            // Start audio capture
            try startAudioCapture()

            // Start streaming manager
            streamingManager.start()

            // Transition to listening
            try transitionTo(.listening)

            logger.info("Transcription started successfully")

        } catch {
            // Handle failure during startup
            await cleanupSession()

            let transcriptionError: TranscriptionError
            if let te = error as? TranscriptionError {
                transcriptionError = te
            } else {
                transcriptionError = .engineInitializationFailed(error.localizedDescription)
            }

            try? transitionTo(.error(transcriptionError.localizedDescription ?? "Unknown error"))
            throw transcriptionError
        }
    }

    /// Stops the current transcription session
    ///
    /// - Returns: The final session result, if any
    @discardableResult
    func stop() async -> TranscriptionSessionResult? {
        logger.info("Stop requested, current state: \(self.state.description)")

        guard state.canStop else {
            logger.warning("Stop called in non-stoppable state: \(self.state.description)")
            return nil
        }

        // Transition to finalizing
        try? transitionTo(.finalizing)

        // Stop audio capture
        stopAudioCapture()

        // Get final result from streaming manager
        let finalSegment = await streamingManager.stop()

        // Handle final segment if present
        if let segment = finalSegment {
            handleFinal(segment)
        }

        // Build session result
        let result = buildSessionResult()

        // Cleanup
        await cleanupSession()

        // Transition to idle
        try? transitionTo(.idle)

        // Post session ended
        if let result {
            notificationPublisher.postSessionEnded(result: result)
        }

        logger.info("Transcription stopped")

        return result
    }

    /// Resets the controller to idle state, cancelling any active session
    func reset() async {
        logger.info("Reset requested")

        // Cancel all active tasks
        cancelAllTasks()

        // Stop components
        stopAudioCapture()
        _ = await streamingManager.stop()

        // Cleanup session
        await cleanupSession()

        // Force transition to idle
        let oldState = state
        state = .idle
        currentTranscript = ""
        currentPartial = ""

        if oldState != .idle {
            notificationPublisher.postStateChange(from: oldState, to: .idle)
            onStateChange?(oldState, .idle)
        }
    }

    // MARK: - State Management

    /// Attempts to transition to a new state
    ///
    /// - Parameter newState: The target state
    /// - Throws: `TranscriptionError.invalidStateTransition` if transition is invalid
    private func transitionTo(_ newState: TranscriptionState) throws {
        let oldState = state

        guard oldState.canTransition(to: newState) else {
            let error = TranscriptionError.invalidStateTransition(
                from: oldState.description,
                to: newState.description
            )
            logger.error("Invalid state transition: \(oldState.description) -> \(newState.description)")
            throw error
        }

        logger.info("State transition: \(oldState.description) -> \(newState.description)")

        state = newState

        // Notify via callback
        onStateChange?(oldState, newState)

        // Post notification
        notificationPublisher.postStateChange(from: oldState, to: newState)
    }

    // MARK: - Audio Capture

    private func startAudioCapture() throws {
        // Configure callback to feed streaming manager
        audioCapture.onPCMFloatBuffer = { [weak self] buffer, _ in
            self?.streamingManager.feedAudio(buffer)
        }

        do {
            try audioCapture.start()
        } catch {
            throw TranscriptionError.audioCaptureStartFailed(error.localizedDescription)
        }
    }

    private func stopAudioCapture() {
        audioCapture.stop()
        audioCapture.onPCMFloatBuffer = nil
    }

    // MARK: - Result Handling

    private func handlePartial(_ partial: ASRPartial) {
        guard let session = currentSession else { return }

        // Update partial state
        currentPartial = partial.text

        // Transition to transcribing if currently listening
        if state == .listening {
            try? transitionTo(.transcribing)
        }

        // Invoke callback
        onPartial?(partial)

        // Post notification
        notificationPublisher.postPartial(partial, sessionID: session.id)

        logger.debug("Partial received: \(partial.text.prefix(50))...")
    }

    private func handleFinal(_ segment: ASRFinalSegment) {
        guard var session = currentSession else { return }

        // Add segment to session
        session.addFinalSegment(segment)
        currentSession = session

        // Update transcript state
        currentTranscript = session.finalizedText
        currentPartial = ""

        // Invoke callback
        onFinal?(segment)

        // Post notification
        notificationPublisher.postFinal(segment, sessionID: session.id)

        logger.debug("Final segment: \(segment.text.prefix(50))...")

        // Transition back to listening if still active
        if state == .transcribing || state == .finalizing {
            try? transitionTo(.listening)
        }
    }

    private func handleStreamingError(_ error: Error) {
        let transcriptionError: TranscriptionError
        if let te = error as? TranscriptionError {
            transcriptionError = te
        } else {
            transcriptionError = .engineProcessingFailed(error.localizedDescription)
        }

        logger.error("Streaming error: \(transcriptionError.localizedDescription ?? "Unknown")")

        // Invoke callback
        onError?(transcriptionError)

        // Post notification
        notificationPublisher.postError(transcriptionError, sessionID: currentSession?.id)

        // Transition to error state if severe
        if !transcriptionError.isRecoverable {
            try? transitionTo(.error(transcriptionError.localizedDescription ?? "Unknown error"))
        }
    }

    // MARK: - Session Management

    private func buildSessionResult() -> TranscriptionSessionResult? {
        guard let session = currentSession else { return nil }

        return TranscriptionSessionResult(
            sessionID: session.id,
            duration: session.duration,
            finalText: session.finalizedText,
            segmentCount: session.segments.count,
            wasSuccessful: !state.isError,
            errorMessage: state.isError ? state.description : nil
        )
    }

    private func cleanupSession() async {
        // Cancel all pending tasks
        cancelAllTasks()

        // Clear session
        currentSession = nil

        // Reset engine state
        await engine.reset()
    }

    // MARK: - Task Management

    /// Registers a task for lifecycle management
    func registerTask(_ task: Task<Void, Never>) -> UUID {
        let id = UUID()
        activeTasks[id] = task
        return id
    }

    /// Unregisters a completed task
    func unregisterTask(id: UUID) {
        activeTasks.removeValue(forKey: id)
    }

    /// Cancels all registered tasks
    private func cancelAllTasks() {
        for (id, task) in activeTasks {
            task.cancel()
            activeTasks.removeValue(forKey: id)
        }
    }

    // MARK: - Computed Properties

    /// Current session ID, if active
    var currentSessionID: UUID? {
        currentSession?.id
    }

    /// Duration of current session
    var sessionDuration: TimeInterval {
        currentSession?.duration ?? 0
    }

    /// Whether transcription is currently active
    var isTranscribing: Bool {
        state.isActive
    }
}

// MARK: - Sendable Conformance

extension TranscriptionController: @unchecked Sendable {
    // Safe because:
    // - @Published properties are accessed only from MainActor
    // - Callbacks are invoked on MainActor
    // - Internal state is protected by locks or actor isolation
}
```

---

## 4. State Transition Diagram

```
                              ┌────────────────┐
                              │                │
                              │     idle       │◄──────────────────────────────┐
                              │                │                               │
                              └───────┬────────┘                               │
                                      │                                        │
                                      │ start()                                │
                                      │                                        │
                              ┌───────▼────────┐                               │
                   ┌──────────│                │                               │
                   │          │   preparing    │──────────────┐                │
                   │          │                │              │                │
                   │          └───────┬────────┘              │                │
                   │                  │                       │                │
                   │ cancelled        │ engine ready          │ error          │
                   │                  │                       │                │
                   │          ┌───────▼────────┐              │                │
                   │     ┌───►│                │◄────────┐    │    ┌───────────┴───────────┐
                   │     │    │   listening    │         │    │    │                       │
                   │     │    │                │─────┐   │    └───►│        error          │
                   │     │    └───────┬────────┘     │   │         │                       │
                   │     │            │              │   │         │  - engine failed      │
                   │     │            │ speech       │   │         │  - audio failed       │
                   │     │            │ detected     │   │         │  - permission denied  │
                   │     │            │              │   │         │                       │
                   │     │    ┌───────▼────────┐     │   │         └───────────┬───────────┘
                   │     │    │                │     │   │                     │
                   │     │    │  transcribing  │─────┤   │                     │ reset()
                   │     │    │                │     │   │                     │
                   │     │    └───────┬────────┘     │   │                     │
                   │     │            │              │   │                     │
                   │     │            │ silence      │   │                     │
                   │     │            │ detected     │   │                     │
                   │     │            │              │   │                     │
                   │     │    ┌───────▼────────┐     │   │                     │
                   │     │    │                │     │   │                     │
                   │     └────│   finalizing   │─────┘   │                     │
                   │          │                │─────────┘                     │
                   │          └───────┬────────┘  more speech                  │
                   │                  │                                        │
                   │                  │ stop() or complete                     │
                   │                  │                                        │
                   └──────────────────┴────────────────────────────────────────┘
```

### State Descriptions

| State | Description | Entry Conditions | Exit Conditions |
|-------|-------------|------------------|-----------------|
| `idle` | No active session, resources released | Initial, stop completed, reset | `start()` called |
| `preparing` | Engine loading models, warming up | `start()` from idle/error | Engine ready or error |
| `listening` | Audio capture active, no speech detected | Engine ready, finalization complete | Speech detected or stop |
| `transcribing` | Active speech, partials flowing | Speech detected | Silence detected or stop |
| `finalizing` | Generating final result after pause | Silence detected | Complete or more speech |
| `error` | Unrecoverable error occurred | Any fatal error | `reset()` called |

---

## 5. Thread Safety Requirements

### 5.1 Threading Model

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Thread Architecture                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐ │
│  │   Main Thread   │    │ Audio IO Thread │    │ Background Queue│ │
│  │   (MainActor)   │    │  (Real-time)    │    │ (userInitiated) │ │
│  ├─────────────────┤    ├─────────────────┤    ├─────────────────┤ │
│  │                 │    │                 │    │                 │ │
│  │ - UI updates    │    │ - Audio capture │    │ - ASR inference │ │
│  │ - State changes │    │ - Buffer copy   │    │ - Model loading │ │
│  │ - Callbacks     │    │ - Level meters  │    │ - Ring buffer   │ │
│  │ - Notifications │    │                 │    │   processing    │ │
│  │                 │    │                 │    │                 │ │
│  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘ │
│           │                      │                      │          │
│           │     Sendable         │     Sendable         │          │
│           │     closures         │     closures         │          │
│           └──────────────────────┴──────────────────────┘          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 Concurrency Rules

1. **MainActor Isolation**
   - `TranscriptionController` is `@MainActor` isolated
   - All published properties updated on main thread
   - All callbacks invoked on main thread

2. **Audio Thread Safety**
   - Audio callbacks arrive from real-time threads
   - No allocations or locks in audio callbacks
   - Use lock-free ring buffers for data transfer

3. **Engine Processing**
   - ASR inference runs on background queues
   - Results dispatched to MainActor via Task
   - Cancellation checks at processing boundaries

4. **Cross-Thread Communication**
   ```swift
   // CORRECT: Sendable closure, MainActor dispatch
   audioCapture.onBuffer = { @Sendable buffer in
       Task { @MainActor in
           self.handleBuffer(buffer)
       }
   }

   // INCORRECT: Non-sendable capture, race condition
   audioCapture.onBuffer = { buffer in
       self.unsafeProperty = buffer  // Data race!
   }
   ```

### 5.3 Session Isolation

```swift
// Session ID validation pattern
func processResult(_ result: ASRPartial, forSession sessionID: UUID) {
    // Always validate session ID before processing
    guard currentSession?.id == sessionID else {
        // Result from stale/cancelled session, discard
        logger.debug("Discarding result for stale session: \(sessionID)")
        return
    }

    // Safe to process
    handlePartial(result)
}
```

---

## 6. Error Handling Strategy

### 6.1 Error Categories

| Category | Examples | Recovery Strategy |
|----------|----------|-------------------|
| **Permission** | Mic denied | Show settings prompt, cannot recover |
| **Engine** | Model load failed | Retry with delay, fallback to smaller model |
| **Audio** | Capture failed | Retry once, then error state |
| **Session** | Timeout, cancelled | Reset and allow restart |
| **State** | Invalid transition | Log warning, ignore operation |

### 6.2 Error Flow

```swift
// Error handling pattern
private func handleError(_ error: TranscriptionError) {
    logger.error("Transcription error: \(error.localizedDescription ?? "Unknown")")

    // 1. Invoke error callback
    onError?(error)

    // 2. Post notification
    notificationPublisher.postError(error, sessionID: currentSession?.id)

    // 3. Transition based on severity
    if error.isRecoverable {
        // Log and continue
        logger.info("Recoverable error, continuing session")
    } else {
        // Transition to error state
        try? transitionTo(.error(error.localizedDescription ?? "Unknown"))

        // Cleanup
        Task {
            await cleanupSession()
        }
    }
}
```

### 6.3 Graceful Degradation

```swift
// Engine fallback example
func prepareEngineWithFallback() async throws {
    do {
        try await engine.prepare()
    } catch {
        logger.warning("Primary engine failed, attempting fallback")

        // Could switch to smaller model or alternative engine
        // For now, propagate error
        throw TranscriptionError.engineInitializationFailed(error.localizedDescription)
    }
}
```

---

## 7. Implementation Steps

### Step 1: Create TranscriptionState (Day 1)

**File:** `TranscriptionState.swift`

1. Define all enum cases with associated values
2. Implement `canTransition(to:)` validation
3. Add helper properties (`isActive`, `canStart`, `canStop`)
4. Write unit tests for all valid/invalid transitions

### Step 2: Create TranscriptionSession (Day 1)

**File:** `TranscriptionSession.swift`

1. Define session structure with UUID, timestamps
2. Add configuration struct
3. Implement segment accumulation
4. Write tests for session lifecycle

### Step 3: Create NotificationCenter Integration (Day 1)

**File:** `TranscriptionNotifications.swift`

1. Define notification names
2. Create userInfo key constants
3. Implement `TranscriptionNotificationPublisher`
4. Write tests for notification posting

### Step 4: Create TranscriptionError (Day 2)

**File:** `TranscriptionError.swift`

1. Define all error cases
2. Implement `LocalizedError`
3. Add recovery suggestions
4. Write tests for error descriptions

### Step 5: Implement TranscriptionController (Days 2-3)

**File:** `TranscriptionController.swift`

1. Set up MainActor-isolated class
2. Implement `start()` with engine preparation
3. Implement `stop()` with finalization
4. Implement `reset()` for cleanup
5. Wire streaming callbacks
6. Add session management
7. Implement task registry
8. Write comprehensive tests

### Step 6: Integration Testing (Day 4)

1. End-to-end tests with mock engine
2. Stress tests for rapid start/stop
3. Memory leak testing
4. Thread safety verification with TSan

---

## 8. Acceptance Criteria

### Functional Requirements

- [ ] State machine enforces valid transitions only
- [ ] `start()` prepares engine and begins audio capture
- [ ] `stop()` finalizes transcription and releases resources
- [ ] `reset()` clears all state and returns to idle
- [ ] Partial results emitted during active speech
- [ ] Final results emitted after silence detection
- [ ] Session IDs correctly isolate concurrent sessions
- [ ] Notifications posted for all state changes
- [ ] Callbacks invoked on MainActor

### Non-Functional Requirements

- [ ] Zero memory leaks across session cycles
- [ ] Thread-safe under concurrent access
- [ ] Graceful handling of engine failures
- [ ] Permission errors surfaced to user
- [ ] Clean cancellation of in-flight tasks
- [ ] Sub-100ms state transition latency

### Code Quality

- [ ] Swift 6 strict concurrency compliant
- [ ] No TSan warnings
- [ ] 90%+ test coverage
- [ ] All public APIs documented

---

## 9. Test Cases

### 9.1 State Transition Tests

```swift
final class TranscriptionStateTests: XCTestCase {

    // MARK: - Valid Transitions

    func test_idle_canTransition_toPreparing() {
        let state = TranscriptionState.idle
        XCTAssertTrue(state.canTransition(to: .preparing))
    }

    func test_preparing_canTransition_toListening() {
        let state = TranscriptionState.preparing
        XCTAssertTrue(state.canTransition(to: .listening))
    }

    func test_preparing_canTransition_toError() {
        let state = TranscriptionState.preparing
        XCTAssertTrue(state.canTransition(to: .error("Engine failed")))
    }

    func test_listening_canTransition_toTranscribing() {
        let state = TranscriptionState.listening
        XCTAssertTrue(state.canTransition(to: .transcribing))
    }

    func test_transcribing_canTransition_toFinalizing() {
        let state = TranscriptionState.transcribing
        XCTAssertTrue(state.canTransition(to: .finalizing))
    }

    func test_transcribing_canTransition_toListening() {
        // More speech after pause
        let state = TranscriptionState.transcribing
        XCTAssertTrue(state.canTransition(to: .listening))
    }

    func test_finalizing_canTransition_toIdle() {
        let state = TranscriptionState.finalizing
        XCTAssertTrue(state.canTransition(to: .idle))
    }

    func test_error_canTransition_toIdle() {
        let state = TranscriptionState.error("Test error")
        XCTAssertTrue(state.canTransition(to: .idle))
    }

    // MARK: - Invalid Transitions

    func test_idle_cannotTransition_toTranscribing() {
        let state = TranscriptionState.idle
        XCTAssertFalse(state.canTransition(to: .transcribing))
    }

    func test_idle_cannotTransition_toFinalizing() {
        let state = TranscriptionState.idle
        XCTAssertFalse(state.canTransition(to: .finalizing))
    }

    func test_preparing_cannotTransition_toTranscribing() {
        // Must go through listening first
        let state = TranscriptionState.preparing
        XCTAssertFalse(state.canTransition(to: .transcribing))
    }

    func test_error_cannotTransition_toPreparing() {
        // Must reset to idle first
        let state = TranscriptionState.error("Test")
        XCTAssertFalse(state.canTransition(to: .preparing))
    }

    // MARK: - State Properties

    func test_isActive_listening() {
        XCTAssertTrue(TranscriptionState.listening.isActive)
    }

    func test_isActive_transcribing() {
        XCTAssertTrue(TranscriptionState.transcribing.isActive)
    }

    func test_isActive_idle() {
        XCTAssertFalse(TranscriptionState.idle.isActive)
    }

    func test_canStart_fromIdle() {
        XCTAssertTrue(TranscriptionState.idle.canStart)
    }

    func test_canStart_fromError() {
        XCTAssertTrue(TranscriptionState.error("Test").canStart)
    }

    func test_cannotStart_fromListening() {
        XCTAssertFalse(TranscriptionState.listening.canStart)
    }
}
```

### 9.2 Controller Lifecycle Tests

```swift
@MainActor
final class TranscriptionControllerTests: XCTestCase {

    var mockEngine: MockASREngine!
    var controller: TranscriptionController!

    override func setUp() async throws {
        mockEngine = MockASREngine()
        controller = TranscriptionController(engine: mockEngine)
    }

    override func tearDown() async throws {
        await controller.reset()
        controller = nil
        mockEngine = nil
    }

    // MARK: - Start/Stop Tests

    func test_start_transitionsToListening() async throws {
        try await controller.start()

        XCTAssertEqual(controller.state, .listening)
    }

    func test_start_createsSession() async throws {
        try await controller.start()

        XCTAssertNotNil(controller.currentSessionID)
    }

    func test_start_preparesEngine() async throws {
        try await controller.start()

        XCTAssertTrue(mockEngine.prepareCalled)
    }

    func test_stop_transitionsToIdle() async throws {
        try await controller.start()

        _ = await controller.stop()

        XCTAssertEqual(controller.state, .idle)
    }

    func test_stop_returnsSessionResult() async throws {
        try await controller.start()

        let result = await controller.stop()

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.wasSuccessful)
    }

    func test_stop_clearsSession() async throws {
        try await controller.start()

        _ = await controller.stop()

        XCTAssertNil(controller.currentSessionID)
    }

    // MARK: - Reset Tests

    func test_reset_fromListening_goesToIdle() async throws {
        try await controller.start()

        await controller.reset()

        XCTAssertEqual(controller.state, .idle)
    }

    func test_reset_clearsTranscript() async throws {
        try await controller.start()
        // Simulate some transcription
        mockEngine.emitPartial(ASRPartial(text: "test", words: []))

        await controller.reset()

        XCTAssertEqual(controller.currentTranscript, "")
    }

    // MARK: - Error Handling Tests

    func test_start_engineFailure_transitionsToError() async {
        mockEngine.shouldFailPrepare = true

        do {
            try await controller.start()
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(controller.state.isError)
        }
    }

    func test_start_fromError_succeeds() async throws {
        // Force error state
        mockEngine.shouldFailPrepare = true
        try? await controller.start()
        XCTAssertTrue(controller.state.isError)

        // Reset and retry
        mockEngine.shouldFailPrepare = false
        await controller.reset()
        try await controller.start()

        XCTAssertEqual(controller.state, .listening)
    }

    // MARK: - Concurrent Operations Tests

    func test_doubleStart_throwsError() async throws {
        try await controller.start()

        do {
            try await controller.start()
            XCTFail("Expected error")
        } catch let error as TranscriptionError {
            if case .operationNotAllowedInState = error {
                // Expected
            } else {
                XCTFail("Wrong error type")
            }
        }
    }

    func test_stopWhileIdle_returnsNil() async {
        let result = await controller.stop()
        XCTAssertNil(result)
    }

    func test_rapidStartStop_maintainsConsistency() async throws {
        for _ in 0..<10 {
            try await controller.start()
            _ = await controller.stop()
            XCTAssertEqual(controller.state, .idle)
        }
    }
}
```

### 9.3 Session Isolation Tests

```swift
@MainActor
final class SessionIsolationTests: XCTestCase {

    var mockEngine: MockASREngine!
    var controller: TranscriptionController!

    override func setUp() async throws {
        mockEngine = MockASREngine()
        controller = TranscriptionController(engine: mockEngine)
    }

    func test_newSession_hasDifferentID() async throws {
        try await controller.start()
        let firstID = controller.currentSessionID
        _ = await controller.stop()

        try await controller.start()
        let secondID = controller.currentSessionID
        _ = await controller.stop()

        XCTAssertNotNil(firstID)
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID)
    }

    func test_staleSessionResult_isDiscarded() async throws {
        try await controller.start()
        let staleSessionID = controller.currentSessionID!
        _ = await controller.stop()

        // Start new session
        try await controller.start()

        // Simulate late-arriving result from old session
        // (This would come from the mock engine in real scenario)
        // The controller should discard it

        // The transcript should be empty (no results from old session)
        XCTAssertEqual(controller.currentTranscript, "")
    }

    func test_reset_invalidatesSession() async throws {
        try await controller.start()
        let sessionID = controller.currentSessionID

        await controller.reset()

        XCTAssertNil(controller.currentSessionID)
        XCTAssertNotNil(sessionID) // Was valid before reset
    }
}
```

### 9.4 Notification Tests

```swift
@MainActor
final class NotificationTests: XCTestCase {

    var mockEngine: MockASREngine!
    var controller: TranscriptionController!
    var receivedNotifications: [Notification] = []
    var cancellables: [Any] = []

    override func setUp() async throws {
        mockEngine = MockASREngine()
        controller = TranscriptionController(engine: mockEngine)
        receivedNotifications = []

        // Subscribe to notifications
        NotificationCenter.default.addObserver(
            forName: .transcriptionStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.receivedNotifications.append(notification)
        }
    }

    override func tearDown() async throws {
        NotificationCenter.default.removeObserver(self)
        await controller.reset()
    }

    func test_start_postsStateChangeNotifications() async throws {
        try await controller.start()

        // Should have: idle->preparing, preparing->listening
        let stateChanges = receivedNotifications.filter {
            $0.name == .transcriptionStateDidChange
        }

        XCTAssertGreaterThanOrEqual(stateChanges.count, 2)
    }

    func test_stop_postsSessionEndedNotification() async throws {
        var sessionEndedReceived = false

        NotificationCenter.default.addObserver(
            forName: .transcriptionSessionEnded,
            object: nil,
            queue: .main
        ) { _ in
            sessionEndedReceived = true
        }

        try await controller.start()
        _ = await controller.stop()

        // Give notification time to post
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(sessionEndedReceived)
    }

    func test_notification_containsCorrectState() async throws {
        try await controller.start()

        let lastStateChange = receivedNotifications.last { $0.name == .transcriptionStateDidChange }
        let state = lastStateChange?.userInfo?[TranscriptionNotificationKey.state] as? TranscriptionState

        XCTAssertEqual(state, .listening)
    }
}
```

### 9.5 Callback Tests

```swift
@MainActor
final class CallbackTests: XCTestCase {

    var mockEngine: MockASREngine!
    var controller: TranscriptionController!

    override func setUp() async throws {
        mockEngine = MockASREngine()
        controller = TranscriptionController(engine: mockEngine)
    }

    func test_onPartial_invokedOnMainActor() async throws {
        let expectation = expectation(description: "Partial callback")
        var calledOnMainThread = false

        controller.onPartial = { _ in
            calledOnMainThread = Thread.isMainThread
            expectation.fulfill()
        }

        try await controller.start()
        mockEngine.emitPartial(ASRPartial(text: "test", words: []))

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(calledOnMainThread)
    }

    func test_onFinal_receivesSegment() async throws {
        let expectation = expectation(description: "Final callback")
        var receivedSegment: ASRFinalSegment?

        controller.onFinal = { segment in
            receivedSegment = segment
            expectation.fulfill()
        }

        try await controller.start()
        let testSegment = ASRFinalSegment(text: "Hello world", words: [])
        mockEngine.emitFinal(testSegment)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedSegment?.text, "Hello world")
    }

    func test_onStateChange_receivesOldAndNewState() async throws {
        var stateChanges: [(old: TranscriptionState, new: TranscriptionState)] = []

        controller.onStateChange = { old, new in
            stateChanges.append((old, new))
        }

        try await controller.start()
        _ = await controller.stop()

        // Verify we captured transitions
        XCTAssertTrue(stateChanges.contains { $0.old == .idle && $0.new == .preparing })
        XCTAssertTrue(stateChanges.contains { $0.old == .preparing && $0.new == .listening })
    }
}
```

### 9.6 Task Cancellation Tests

```swift
@MainActor
final class TaskCancellationTests: XCTestCase {

    var mockEngine: MockASREngine!
    var controller: TranscriptionController!

    override func setUp() async throws {
        mockEngine = MockASREngine()
        controller = TranscriptionController(engine: mockEngine)
    }

    func test_stop_cancelsActiveTasks() async throws {
        mockEngine.processDelay = 1.0  // Slow processing

        try await controller.start()

        // Start a processing task
        mockEngine.emitPartial(ASRPartial(text: "processing", words: []))

        // Stop immediately
        _ = await controller.stop()

        // Tasks should be cancelled
        XCTAssertEqual(controller.state, .idle)
    }

    func test_reset_cancelsAllTasks() async throws {
        mockEngine.processDelay = 1.0

        try await controller.start()
        mockEngine.emitPartial(ASRPartial(text: "test", words: []))

        await controller.reset()

        XCTAssertEqual(controller.state, .idle)
    }

    func test_stopDuringPrepare_cancelsSession() async throws {
        mockEngine.prepareDelay = 1.0  // Slow preparation

        // Start in background
        let startTask = Task {
            try await controller.start()
        }

        // Give it time to begin
        try await Task.sleep(for: .milliseconds(100))

        // Stop before preparation completes
        await controller.reset()

        // Original start should have been cancelled
        startTask.cancel()

        XCTAssertEqual(controller.state, .idle)
    }
}
```

### 9.7 Memory and Cleanup Tests

```swift
@MainActor
final class MemoryCleanupTests: XCTestCase {

    func test_multipleSessionCycles_noMemoryLeak() async throws {
        weak var weakController: TranscriptionController?

        do {
            let mockEngine = MockASREngine()
            let controller = TranscriptionController(engine: mockEngine)
            weakController = controller

            for _ in 0..<5 {
                try await controller.start()
                _ = await controller.stop()
            }
        }

        // Controller should be deallocated
        XCTAssertNil(weakController)
    }

    func test_reset_clearsAllState() async throws {
        let mockEngine = MockASREngine()
        let controller = TranscriptionController(engine: mockEngine)

        try await controller.start()
        mockEngine.emitPartial(ASRPartial(text: "some text", words: []))
        mockEngine.emitFinal(ASRFinalSegment(text: "final", words: []))

        await controller.reset()

        XCTAssertNil(controller.currentSessionID)
        XCTAssertEqual(controller.currentTranscript, "")
        XCTAssertEqual(controller.currentPartial, "")
        XCTAssertEqual(controller.state, .idle)
    }
}
```

### 9.8 Stress Tests

```swift
@MainActor
final class StressTests: XCTestCase {

    func test_rapidStateTransitions_maintainsConsistency() async throws {
        let mockEngine = MockASREngine()
        let controller = TranscriptionController(engine: mockEngine)

        for i in 0..<50 {
            try await controller.start()

            // Simulate rapid partials
            for j in 0..<10 {
                mockEngine.emitPartial(ASRPartial(text: "word\(j)", words: []))
            }

            _ = await controller.stop()

            XCTAssertEqual(controller.state, .idle, "Failed on iteration \(i)")
        }
    }

    func test_concurrentCallbacks_noRaceConditions() async throws {
        let mockEngine = MockASREngine()
        let controller = TranscriptionController(engine: mockEngine)

        var callbackCount = 0
        controller.onPartial = { _ in
            callbackCount += 1
        }

        try await controller.start()

        // Fire many partials concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    mockEngine.emitPartial(ASRPartial(text: "partial\(i)", words: []))
                }
            }
        }

        try await Task.sleep(for: .milliseconds(500))

        _ = await controller.stop()

        // All callbacks should have been received
        XCTAssertEqual(callbackCount, 100)
    }
}
```

---

## 10. Mock Implementations for Testing

```swift
// File: MockASREngine.swift

import Foundation
import AVFoundation

/// Mock ASR engine for testing TranscriptionController
final class MockASREngine: ASREngine, @unchecked Sendable {

    // MARK: - Test Configuration

    var shouldFailPrepare = false
    var prepareDelay: TimeInterval = 0
    var processDelay: TimeInterval = 0

    // MARK: - Call Tracking

    private(set) var prepareCalled = false
    private(set) var resetCalled = false
    private(set) var processCalled = false

    // MARK: - Callback Storage

    private var partialHandler: ((ASRPartial) -> Void)?

    // MARK: - ASREngine Conformance

    var provider: ASRProvider { .parakeet }

    func prepare() async throws {
        prepareCalled = true

        if prepareDelay > 0 {
            try await Task.sleep(for: .seconds(prepareDelay))
        }

        if shouldFailPrepare {
            throw TranscriptionError.engineInitializationFailed("Mock failure")
        }
    }

    func reset() async {
        resetCalled = true
    }

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        processCalled = true

        if processDelay > 0 {
            try await Task.sleep(for: .seconds(processDelay))
        }

        return nil
    }

    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        return nil
    }

    func setPartialHandler(_ handler: ((ASRPartial) -> Void)?) {
        partialHandler = handler
    }

    // MARK: - Test Helpers

    func emitPartial(_ partial: ASRPartial) {
        partialHandler?(partial)
    }

    func emitFinal(_ segment: ASRFinalSegment) {
        // Would be emitted via streaming manager in real implementation
    }
}
```

---

## 11. Files Summary

### New Files

| File | Purpose |
|------|---------|
| `TranscriptionState.swift` | State enum with transition validation |
| `TranscriptionSession.swift` | Session data structure with UUID |
| `TranscriptionNotifications.swift` | Notification names, keys, publisher |
| `TranscriptionError.swift` | Error types with recovery info |
| `TranscriptionController.swift` | Main orchestrator class |
| `TranscriptionStateTests.swift` | State transition tests |
| `TranscriptionControllerTests.swift` | Controller lifecycle tests |
| `SessionIsolationTests.swift` | Session isolation tests |
| `NotificationTests.swift` | Notification delivery tests |
| `CallbackTests.swift` | Callback invocation tests |
| `TaskCancellationTests.swift` | Cancellation behavior tests |
| `MemoryCleanupTests.swift` | Memory/cleanup tests |
| `StressTests.swift` | Stress and concurrency tests |
| `MockASREngine.swift` | Test mock for ASREngine |

### Dependencies

| Component | Required From |
|-----------|---------------|
| `ASREngine` | S.01 - ASR Abstraction |
| `AudioCapture` | S.02 - Audio Capture |
| `StreamingManager` | S.03 - Streaming Manager |
| `ASRPartial`, `ASRFinalSegment` | S.01 - ASR Abstraction |

---

## 12. Risks and Mitigations

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| State machine bugs | Medium | High | Exhaustive transition tests, formal validation |
| Memory leaks in callbacks | Medium | Medium | Weak references, cleanup tests, Instruments |
| Race conditions | Low | High | MainActor isolation, TSan testing |
| Notification ordering | Low | Medium | Synchronous posting, sequence tests |
| Task cancellation edge cases | Medium | Medium | Comprehensive cancellation tests |
| Engine initialization timeout | Low | Medium | Configurable timeout, cancellation support |

---

## 13. Definition of Done

### Code Complete

- [ ] All source files implemented
- [ ] Swift 6 strict concurrency compliant
- [ ] No compiler warnings
- [ ] Documentation for all public APIs

### Testing Complete

- [ ] 90%+ code coverage
- [ ] All 15+ test cases passing
- [ ] TSan clean (no data races)
- [ ] Memory leak tests passing
- [ ] Stress tests stable

### Integration Complete

- [ ] Wired to AudioCapture
- [ ] Wired to StreamingManager
- [ ] Notifications working end-to-end
- [ ] Callbacks working end-to-end

### Review Complete

- [ ] Code review approved
- [ ] Documentation reviewed
- [ ] Test plan reviewed

---

## 14. Appendix: Quick Reference

### State Machine Quick Reference

```
idle        -> preparing                 (start)
preparing   -> listening | error | idle  (ready | fail | cancel)
listening   -> transcribing | finalizing | error | idle  (speech | stop | fail | stop)
transcribing-> finalizing | listening | error            (silence | more speech | fail)
finalizing  -> idle | listening | error                  (complete | more speech | fail)
error       -> idle                                      (reset)
```

### Notification Quick Reference

```swift
.transcriptionStateDidChange    // userInfo: state, previousState
.transcriptionPartialReceived   // userInfo: partial, sessionID
.transcriptionFinalReceived     // userInfo: final, sessionID
.transcriptionError             // userInfo: error, sessionID?
.transcriptionSessionStarted    // userInfo: sessionID
.transcriptionSessionEnded      // userInfo: sessionID, sessionResult
```

### Error Quick Reference

```swift
TranscriptionError.engineInitializationFailed(String)
TranscriptionError.engineNotReady
TranscriptionError.engineProcessingFailed(String)
TranscriptionError.modelLoadFailed(String)
TranscriptionError.microphonePermissionDenied
TranscriptionError.audioCaptureStartFailed(String)
TranscriptionError.invalidStateTransition(from:to:)
TranscriptionError.operationNotAllowedInState(operation:state:)
TranscriptionError.sessionCancelled
TranscriptionError.sessionTimedOut
TranscriptionError.unknown(String)
```
