# E.01 - Error Recovery & Fallbacks

**Epic:** Reliability
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** O.02 (Conversation Orchestrator), All component services
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement unified error handling, recovery strategies, and graceful degradation across all Ora components. Users should never see crashes, and failures should be handled with clear feedback and automatic recovery where possible.

---

## 2. Error Categories

### 2.1 Error Taxonomy

| Category | Recoverable | User Action Required | Examples |
|:---------|:------------|:---------------------|:---------|
| **Transient** | Yes (auto) | No | Network timeout, temporary unavailable |
| **Resource** | Yes (after cleanup) | Sometimes | OOM, disk full, model too large |
| **Permission** | No | Yes | Microphone denied, calendar access revoked |
| **Configuration** | No | Yes | Model corrupted, missing files |
| **User** | N/A | No | Cancelled, timeout waiting for confirmation |
| **Unknown** | Maybe | Maybe | Unexpected exceptions |

### 2.2 Component-Specific Errors

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Error Sources                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Audio/ASR:                    LLM:                      TTS:               │
│  ├─ Microphone unavailable     ├─ Model not loaded       ├─ Model not loaded│
│  ├─ Audio format mismatch      ├─ OOM during generation  ├─ OOM during synth│
│  ├─ ASR engine timeout         ├─ Generation timeout     ├─ Audio playback  │
│  ├─ No speech detected         ├─ Invalid JSON output    │   failure        │
│  └─ Engine crash               ├─ Context too long       └─ Engine crash    │
│                                └─ Engine crash                               │
│                                                                              │
│  Tools:                        Orchestration:                               │
│  ├─ Permission denied          ├─ Pipeline timeout                          │
│  ├─ Resource not found         ├─ State machine invalid                     │
│  ├─ Validation failed          ├─ Confirmation timeout                      │
│  ├─ Execution failed           └─ Cancellation                              │
│  └─ Rate limited                                                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Architecture

### 3.1 Error Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Error Handling Flow                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Component Error                                                            │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────┐                                                            │
│  │ ErrorMapper │ ──► Categorize error, determine recoverability             │
│  └──────┬──────┘                                                            │
│         │                                                                    │
│         ▼                                                                    │
│  ┌─────────────────┐                                                        │
│  │ RecoveryManager │ ──► Attempt automatic recovery if possible             │
│  └────────┬────────┘                                                        │
│           │                                                                  │
│     ┌─────┴─────┐                                                           │
│     │           │                                                            │
│     ▼           ▼                                                            │
│  Recovered   Still Failed                                                   │
│     │           │                                                            │
│     │           ▼                                                            │
│     │    ┌─────────────┐                                                    │
│     │    │ ErrorPresenter│ ──► Show user-friendly message                   │
│     │    └──────┬──────┘                                                    │
│     │           │                                                            │
│     │           ▼                                                            │
│     │    ┌─────────────┐                                                    │
│     │    │ FallbackManager│ ──► Activate graceful degradation               │
│     │    └──────┬──────┘                                                    │
│     │           │                                                            │
│     └─────┬─────┘                                                           │
│           │                                                                  │
│           ▼                                                                  │
│  ┌─────────────┐                                                            │
│  │ AuditLogger │ ──► Log error for debugging                               │
│  └─────────────┘                                                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Implementation

### 4.1 Error Types

**File:** `Ora/Reliability/OraError.swift`

```swift
//
//  OraError.swift
//  Ora
//
//  Unified error types for the application
//

import Foundation

/// Base error protocol for all Ora errors
protocol OraError: LocalizedError, Sendable {
    var category: ErrorCategory { get }
    var isRecoverable: Bool { get }
    var recoveryStrategy: RecoveryStrategy { get }
    var userMessage: String { get }
    var technicalDetails: String { get }
}

/// Error categories
enum ErrorCategory: String, Sendable {
    case transient      // Temporary failures, retry may help
    case resource       // Memory, disk, compute constraints
    case permission     // System permission issues
    case configuration  // Setup/model issues
    case user           // User-initiated (cancel, timeout)
    case unknown        // Unexpected errors
}

/// Recovery strategies
enum RecoveryStrategy: Sendable {
    case retry(maxAttempts: Int, backoff: BackoffStrategy)
    case reloadModel
    case freeMemoryAndRetry
    case promptUser(action: UserAction)
    case fallback(FallbackMode)
    case abort
}

enum BackoffStrategy: Sendable {
    case immediate
    case linear(baseMs: Int)
    case exponential(baseMs: Int, maxMs: Int)
}

enum UserAction: String, Sendable {
    case grantPermission = "Open Settings to grant permission"
    case downloadModel = "Download required model"
    case restartApp = "Restart Ora"
    case contactSupport = "Contact support"
}

enum FallbackMode: Sendable {
    case textOnly           // TTS failed, show text
    case offlineMode        // Network unavailable
    case reducedFunctionality(reason: String)
    case dictationOnly      // LLM failed, ASR still works
}

// MARK: - Audio/ASR Errors

enum ASRError: OraError {
    case microphoneUnavailable
    case microphoneDenied
    case engineNotReady
    case engineTimeout
    case noSpeechDetected
    case engineCrash(underlying: Error?)
    case audioFormatMismatch
    
    var category: ErrorCategory {
        switch self {
        case .microphoneDenied: return .permission
        case .engineTimeout, .noSpeechDetected: return .transient
        case .microphoneUnavailable, .audioFormatMismatch: return .configuration
        case .engineNotReady, .engineCrash: return .resource
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .microphoneDenied: return false
        case .engineTimeout, .noSpeechDetected, .engineNotReady: return true
        case .microphoneUnavailable, .engineCrash, .audioFormatMismatch: return false
        }
    }
    
    var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .microphoneDenied:
            return .promptUser(action: .grantPermission)
        case .engineTimeout:
            return .retry(maxAttempts: 2, backoff: .exponential(baseMs: 500, maxMs: 2000))
        case .noSpeechDetected:
            return .abort  // User just didn't speak
        case .engineNotReady:
            return .reloadModel
        case .engineCrash:
            return .fallback(.dictationOnly)
        case .microphoneUnavailable, .audioFormatMismatch:
            return .promptUser(action: .restartApp)
        }
    }
    
    var userMessage: String {
        switch self {
        case .microphoneUnavailable:
            return "Microphone is not available. Please check your audio settings."
        case .microphoneDenied:
            return "Microphone access was denied. Please enable it in System Settings."
        case .engineNotReady:
            return "Speech recognition is starting up. Please try again."
        case .engineTimeout:
            return "Speech recognition took too long. Please try again."
        case .noSpeechDetected:
            return "I didn't hear anything. Please try speaking again."
        case .engineCrash:
            return "Speech recognition encountered an error. Restarting..."
        case .audioFormatMismatch:
            return "Audio format error. Please restart Ora."
        }
    }
    
    var technicalDetails: String {
        switch self {
        case .microphoneUnavailable: return "AVAudioSession microphone unavailable"
        case .microphoneDenied: return "AVAudioSession.recordPermission == .denied"
        case .engineNotReady: return "ASRService.isReady == false"
        case .engineTimeout: return "ASR generation exceeded timeout"
        case .noSpeechDetected: return "VAD detected no speech in audio buffer"
        case .engineCrash(let error): return "ASR engine crashed: \(error?.localizedDescription ?? "unknown")"
        case .audioFormatMismatch: return "Audio format incompatible with ASR engine"
        }
    }
    
    var errorDescription: String? { userMessage }
}

// MARK: - LLM Errors

enum LLMError: OraError {
    case modelNotLoaded
    case modelNotFound
    case outOfMemory
    case generationTimeout
    case invalidOutput(reason: String)
    case contextTooLong(current: Int, max: Int)
    case engineCrash(underlying: Error?)
    
    var category: ErrorCategory {
        switch self {
        case .modelNotLoaded, .modelNotFound: return .configuration
        case .outOfMemory, .contextTooLong: return .resource
        case .generationTimeout, .invalidOutput: return .transient
        case .engineCrash: return .unknown
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .generationTimeout, .invalidOutput: return true
        case .outOfMemory, .contextTooLong: return true  // After cleanup
        case .modelNotLoaded: return true
        case .modelNotFound, .engineCrash: return false
        }
    }
    
    var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .modelNotLoaded:
            return .reloadModel
        case .modelNotFound:
            return .promptUser(action: .downloadModel)
        case .outOfMemory:
            return .freeMemoryAndRetry
        case .generationTimeout:
            return .retry(maxAttempts: 1, backoff: .immediate)
        case .invalidOutput:
            return .retry(maxAttempts: 2, backoff: .immediate)
        case .contextTooLong:
            return .freeMemoryAndRetry  // Truncate context
        case .engineCrash:
            return .fallback(.textOnly)
        }
    }
    
    var userMessage: String {
        switch self {
        case .modelNotLoaded:
            return "The AI model is loading. Please wait a moment."
        case .modelNotFound:
            return "AI model not found. Please download it in Preferences."
        case .outOfMemory:
            return "Not enough memory available. Freeing resources..."
        case .generationTimeout:
            return "Response took too long. Please try again."
        case .invalidOutput:
            return "I had trouble forming a response. Let me try again."
        case .contextTooLong:
            return "The conversation is too long. Starting fresh."
        case .engineCrash:
            return "The AI encountered an error. Please try again."
        }
    }
    
    var technicalDetails: String {
        switch self {
        case .modelNotLoaded: return "LLMService.isReady == false"
        case .modelNotFound: return "Model path does not exist"
        case .outOfMemory: return "MLX allocation failed, likely OOM"
        case .generationTimeout: return "Token generation exceeded timeout"
        case .invalidOutput(let reason): return "JSON validation failed: \(reason)"
        case .contextTooLong(let current, let max): return "Context \(current) exceeds max \(max)"
        case .engineCrash(let error): return "LLM engine crashed: \(error?.localizedDescription ?? "unknown")"
        }
    }
    
    var errorDescription: String? { userMessage }
}

// MARK: - TTS Errors

enum TTSError: OraError {
    case modelNotLoaded
    case outOfMemory
    case synthesisTimeout
    case playbackFailed(underlying: Error?)
    case engineCrash(underlying: Error?)
    
    var category: ErrorCategory {
        switch self {
        case .modelNotLoaded: return .configuration
        case .outOfMemory: return .resource
        case .synthesisTimeout: return .transient
        case .playbackFailed, .engineCrash: return .unknown
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .synthesisTimeout: return true
        case .modelNotLoaded, .outOfMemory: return true
        case .playbackFailed, .engineCrash: return false
        }
    }
    
    var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .modelNotLoaded:
            return .reloadModel
        case .outOfMemory:
            return .freeMemoryAndRetry
        case .synthesisTimeout:
            return .retry(maxAttempts: 1, backoff: .immediate)
        case .playbackFailed, .engineCrash:
            return .fallback(.textOnly)
        }
    }
    
    var userMessage: String {
        switch self {
        case .modelNotLoaded:
            return "Voice synthesis is loading..."
        case .outOfMemory:
            return "Not enough memory for voice. Showing text instead."
        case .synthesisTimeout:
            return "Voice generation was slow. Showing text instead."
        case .playbackFailed:
            return "Couldn't play audio. Check your speakers."
        case .engineCrash:
            return "Voice synthesis error. Showing text instead."
        }
    }
    
    var technicalDetails: String {
        switch self {
        case .modelNotLoaded: return "TTSService.isReady == false"
        case .outOfMemory: return "Kokoro allocation failed, OOM"
        case .synthesisTimeout: return "TTS synthesis exceeded timeout"
        case .playbackFailed(let error): return "AVAudioPlayer failed: \(error?.localizedDescription ?? "unknown")"
        case .engineCrash(let error): return "TTS engine crashed: \(error?.localizedDescription ?? "unknown")"
        }
    }
    
    var errorDescription: String? { userMessage }
}

// MARK: - Tool Errors

enum ToolError: OraError {
    case permissionDenied(tool: String, permission: String)
    case resourceNotFound(tool: String, resource: String)
    case validationFailed(tool: String, reason: String)
    case executionFailed(tool: String, underlying: Error?)
    case rateLimited(tool: String, retryAfter: TimeInterval?)
    
    var category: ErrorCategory {
        switch self {
        case .permissionDenied: return .permission
        case .resourceNotFound: return .transient
        case .validationFailed: return .configuration
        case .executionFailed: return .unknown
        case .rateLimited: return .transient
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .permissionDenied: return false
        case .resourceNotFound, .executionFailed, .rateLimited: return true
        case .validationFailed: return false
        }
    }
    
    var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .permissionDenied:
            return .promptUser(action: .grantPermission)
        case .resourceNotFound:
            return .abort  // Let LLM handle "not found"
        case .validationFailed:
            return .abort  // LLM needs to fix arguments
        case .executionFailed:
            return .retry(maxAttempts: 2, backoff: .exponential(baseMs: 200, maxMs: 1000))
        case .rateLimited(_, let retryAfter):
            let delay = Int((retryAfter ?? 1.0) * 1000)
            return .retry(maxAttempts: 1, backoff: .linear(baseMs: delay))
        }
    }
    
    var userMessage: String {
        switch self {
        case .permissionDenied(let tool, _):
            return "I don't have permission to access \(tool). Please check System Settings."
        case .resourceNotFound(_, let resource):
            return "I couldn't find \(resource)."
        case .validationFailed(let tool, _):
            return "I had trouble with the \(tool) request. Could you rephrase?"
        case .executionFailed(let tool, _):
            return "The \(tool) action failed. Let me try again."
        case .rateLimited(let tool, _):
            return "Too many requests to \(tool). Please wait a moment."
        }
    }
    
    var technicalDetails: String {
        switch self {
        case .permissionDenied(let tool, let perm): return "\(tool): permission \(perm) denied"
        case .resourceNotFound(let tool, let res): return "\(tool): resource '\(res)' not found"
        case .validationFailed(let tool, let reason): return "\(tool): validation failed - \(reason)"
        case .executionFailed(let tool, let error): return "\(tool): execution failed - \(error?.localizedDescription ?? "unknown")"
        case .rateLimited(let tool, let retry): return "\(tool): rate limited, retry after \(retry ?? 0)s"
        }
    }
    
    var errorDescription: String? { userMessage }
}

// MARK: - Orchestration Errors

enum OrchestrationError: OraError {
    case pipelineTimeout
    case cancelled
    case confirmationTimeout
    case invalidState(expected: String, actual: String)
    
    var category: ErrorCategory {
        switch self {
        case .pipelineTimeout: return .transient
        case .cancelled, .confirmationTimeout: return .user
        case .invalidState: return .unknown
        }
    }
    
    var isRecoverable: Bool {
        switch self {
        case .pipelineTimeout: return true
        case .cancelled, .confirmationTimeout: return false  // User-initiated
        case .invalidState: return false
        }
    }
    
    var recoveryStrategy: RecoveryStrategy {
        switch self {
        case .pipelineTimeout:
            return .retry(maxAttempts: 1, backoff: .immediate)
        case .cancelled, .confirmationTimeout:
            return .abort
        case .invalidState:
            return .promptUser(action: .restartApp)
        }
    }
    
    var userMessage: String {
        switch self {
        case .pipelineTimeout:
            return "The request took too long. Please try again."
        case .cancelled:
            return "Request cancelled."
        case .confirmationTimeout:
            return "The confirmation timed out."
        case .invalidState:
            return "Something went wrong. Please try again."
        }
    }
    
    var technicalDetails: String {
        switch self {
        case .pipelineTimeout: return "Full pipeline exceeded timeout threshold"
        case .cancelled: return "User cancelled via hotkey/button"
        case .confirmationTimeout: return "Confirmation gate timed out (60s)"
        case .invalidState(let expected, let actual): return "State machine: expected \(expected), got \(actual)"
        }
    }
    
    var errorDescription: String? { userMessage }
}
```

### 4.2 Recovery Manager

**File:** `Ora/Reliability/RecoveryManager.swift`

```swift
//
//  RecoveryManager.swift
//  Ora
//
//  Handles automatic error recovery
//

import Foundation
import os

/// Manages automatic error recovery
actor RecoveryManager {
    
    // MARK: - Singleton
    
    static let shared = RecoveryManager()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "Recovery")
    
    private var retryAttempts: [String: Int] = [:]
    private var lastRecoveryTime: Date?
    
    // Memory pressure tracking
    private var isInLowMemoryMode = false
    
    // MARK: - Initialization
    
    private init() {
        setupMemoryWarningObserver()
    }
    
    // MARK: - Public API
    
    /// Attempt to recover from an error
    func attemptRecovery(
        for error: any OraError,
        context: String
    ) async -> RecoveryResult {
        
        logger.info("Attempting recovery for \(context): \(error.technicalDetails)")
        
        switch error.recoveryStrategy {
        case .retry(let maxAttempts, let backoff):
            return await handleRetry(
                context: context,
                maxAttempts: maxAttempts,
                backoff: backoff
            )
            
        case .reloadModel:
            return await handleModelReload()
            
        case .freeMemoryAndRetry:
            return await handleMemoryPressure()
            
        case .promptUser(let action):
            return .requiresUserAction(action)
            
        case .fallback(let mode):
            return .fallbackActivated(mode)
            
        case .abort:
            return .aborted
        }
    }
    
    /// Reset retry counts (call on successful operation)
    func resetRetries(for context: String) {
        retryAttempts[context] = nil
    }
    
    /// Check if we're in degraded mode
    var isDegraded: Bool {
        isInLowMemoryMode
    }
    
    // MARK: - Private - Retry
    
    private func handleRetry(
        context: String,
        maxAttempts: Int,
        backoff: BackoffStrategy
    ) async -> RecoveryResult {
        
        let currentAttempt = (retryAttempts[context] ?? 0) + 1
        retryAttempts[context] = currentAttempt
        
        guard currentAttempt <= maxAttempts else {
            logger.warning("Max retries exceeded for \(context)")
            retryAttempts[context] = nil
            return .maxRetriesExceeded
        }
        
        // Calculate delay
        let delayMs = calculateDelay(attempt: currentAttempt, backoff: backoff)
        
        logger.debug("Retry \(currentAttempt)/\(maxAttempts) for \(context), delay \(delayMs)ms")
        
        if delayMs > 0 {
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        
        return .shouldRetry(attempt: currentAttempt, of: maxAttempts)
    }
    
    private func calculateDelay(attempt: Int, backoff: BackoffStrategy) -> Int {
        switch backoff {
        case .immediate:
            return 0
        case .linear(let baseMs):
            return baseMs * attempt
        case .exponential(let baseMs, let maxMs):
            let delay = baseMs * Int(pow(2.0, Double(attempt - 1)))
            return min(delay, maxMs)
        }
    }
    
    // MARK: - Private - Model Reload
    
    private func handleModelReload() async -> RecoveryResult {
        logger.info("Attempting model reload")
        
        do {
            // Unload and reload LLM
            await LLMService.shared.unload()
            try await LLMService.shared.prepare()
            try await LLMService.shared.warmup()
            
            logger.info("Model reload successful")
            return .recovered
            
        } catch {
            logger.error("Model reload failed: \(error.localizedDescription)")
            return .recoveryFailed(error)
        }
    }
    
    // MARK: - Private - Memory Pressure
    
    private func handleMemoryPressure() async -> RecoveryResult {
        logger.warning("Handling memory pressure")
        
        isInLowMemoryMode = true
        
        // 1. Clear caches
        await ConversationManager.shared.truncateHistory(keepLast: 2)
        
        // 2. Unload non-essential models
        // TTS is optional - can fall back to AVSpeechSynthesizer
        await TTSService.shared.unloadIfPossible()
        
        // 3. Force garbage collection
        autoreleasepool { }
        
        // 4. Wait a moment for memory to free
        try? await Task.sleep(for: .milliseconds(500))
        
        logger.info("Memory cleanup complete")
        return .shouldRetry(attempt: 1, of: 1)
    }
    
    private func setupMemoryWarningObserver() {
        // macOS doesn't have UIKit memory warnings, but we can monitor
        // We'll rely on catching OOM errors instead
    }
}

// MARK: - Recovery Result

enum RecoveryResult: Sendable {
    case recovered
    case shouldRetry(attempt: Int, of: Int)
    case maxRetriesExceeded
    case requiresUserAction(UserAction)
    case fallbackActivated(FallbackMode)
    case recoveryFailed(Error)
    case aborted
}
```

### 4.3 Fallback Manager

**File:** `Ora/Reliability/FallbackManager.swift`

```swift
//
//  FallbackManager.swift
//  Ora
//
//  Manages graceful degradation modes
//

import Foundation
import os

/// Tracks and manages fallback modes
@MainActor
final class FallbackManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = FallbackManager()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "Fallback")
    
    @Published private(set) var activeFallbacks: Set<FallbackMode> = []
    @Published private(set) var isFullyOperational: Bool = true
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Activate a fallback mode
    func activate(_ mode: FallbackMode) {
        guard !activeFallbacks.contains(mode) else { return }
        
        activeFallbacks.insert(mode)
        isFullyOperational = activeFallbacks.isEmpty
        
        logger.warning("Fallback activated: \(String(describing: mode))")
        
        // Post notification for UI
        NotificationCenter.default.post(
            name: .fallbackModeChanged,
            object: self,
            userInfo: ["mode": mode, "active": true]
        )
    }
    
    /// Deactivate a fallback mode
    func deactivate(_ mode: FallbackMode) {
        guard activeFallbacks.contains(mode) else { return }
        
        activeFallbacks.remove(mode)
        isFullyOperational = activeFallbacks.isEmpty
        
        logger.info("Fallback deactivated: \(String(describing: mode))")
        
        NotificationCenter.default.post(
            name: .fallbackModeChanged,
            object: self,
            userInfo: ["mode": mode, "active": false]
        )
    }
    
    /// Check if a specific capability is available
    func isAvailable(_ capability: Capability) -> Bool {
        switch capability {
        case .voiceOutput:
            return !activeFallbacks.contains(.textOnly)
        case .llmReasoning:
            return !activeFallbacks.contains(.dictationOnly)
        case .fullFunctionality:
            return isFullyOperational
        }
    }
    
    /// Get user-facing status message
    var statusMessage: String? {
        if activeFallbacks.isEmpty {
            return nil
        }
        
        if activeFallbacks.contains(.dictationOnly) {
            return "Running in dictation-only mode"
        }
        
        if activeFallbacks.contains(.textOnly) {
            return "Voice output unavailable"
        }
        
        if let reduced = activeFallbacks.first(where: {
            if case .reducedFunctionality = $0 { return true }
            return false
        }), case .reducedFunctionality(let reason) = reduced {
            return reason
        }
        
        return "Running with limited functionality"
    }
    
    /// Reset all fallbacks (e.g., on app restart)
    func reset() {
        activeFallbacks.removeAll()
        isFullyOperational = true
    }
}

// MARK: - Capability

enum Capability: Sendable {
    case voiceOutput
    case llmReasoning
    case fullFunctionality
}

// MARK: - Notification

extension Notification.Name {
    static let fallbackModeChanged = Notification.Name("fallbackModeChanged")
}

// MARK: - FallbackMode Hashable

extension FallbackMode: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .textOnly:
            hasher.combine("textOnly")
        case .offlineMode:
            hasher.combine("offlineMode")
        case .dictationOnly:
            hasher.combine("dictationOnly")
        case .reducedFunctionality(let reason):
            hasher.combine("reduced")
            hasher.combine(reason)
        }
    }
    
    static func == (lhs: FallbackMode, rhs: FallbackMode) -> Bool {
        switch (lhs, rhs) {
        case (.textOnly, .textOnly): return true
        case (.offlineMode, .offlineMode): return true
        case (.dictationOnly, .dictationOnly): return true
        case (.reducedFunctionality(let l), .reducedFunctionality(let r)): return l == r
        default: return false
        }
    }
}
```

### 4.4 Error Presenter

**File:** `Ora/Reliability/ErrorPresenter.swift`

```swift
//
//  ErrorPresenter.swift
//  Ora
//
//  Presents errors to users in a friendly way
//

import Foundation
import os

/// Presents errors to users
@MainActor
final class ErrorPresenter {
    
    // MARK: - Singleton
    
    static let shared = ErrorPresenter()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "ErrorPresenter")
    
    // Rate limit error display
    private var lastErrorTime: Date?
    private var errorCount = 0
    private let maxErrorsPerMinute = 5
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Present an error to the user
    func present(_ error: any OraError, in context: ErrorContext) {
        // Rate limiting to avoid error spam
        let now = Date()
        if let lastTime = lastErrorTime, now.timeIntervalSince(lastTime) < 60 {
            errorCount += 1
            if errorCount > maxErrorsPerMinute {
                logger.warning("Error rate limit exceeded, suppressing display")
                return
            }
        } else {
            lastErrorTime = now
            errorCount = 1
        }
        
        logger.info("Presenting error: \(error.userMessage)")
        
        // Log technical details
        AuditLogger.shared.recordError(
            category: error.category.rawValue,
            message: error.userMessage,
            technicalDetails: error.technicalDetails
        )
        
        // Present based on context
        switch context {
        case .overlay:
            presentInOverlay(error)
        case .notification:
            presentAsNotification(error)
        case .silent:
            // Just log, don't show to user
            break
        }
    }
    
    // MARK: - Private
    
    private func presentInOverlay(_ error: any OraError) {
        // Update overlay to show error state
        OverlayWindowController.shared.mode = .error(error.userMessage)
        
        // If requires user action, show more detail
        if case .promptUser(let action) = error.recoveryStrategy {
            // Could show a button to open settings, etc.
            showActionableError(message: error.userMessage, action: action)
        }
    }
    
    private func presentAsNotification(_ error: any OraError) {
        // Use macOS notification center for background errors
        let content = UNMutableNotificationContent()
        content.title = "Ora"
        content.body = error.userMessage
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func showActionableError(message: String, action: UserAction) {
        // For now, just update overlay
        // Could show a sheet with action button
        logger.info("Actionable error: \(action.rawValue)")
    }
}

// MARK: - Error Context

enum ErrorContext: Sendable {
    case overlay     // Show in the active overlay
    case notification // Show as system notification
    case silent      // Log only, don't show
}
```

### 4.5 Integration with Orchestrator

**Update:** `Ora/Orchestration/ConversationOrchestrator.swift`

Add error handling integration:

```swift
// In ConversationOrchestrator

private func handleError(_ error: Error) {
    // Map to OraError if possible
    let oraError: any OraError
    if let mapped = error as? any OraError {
        oraError = mapped
    } else {
        // Wrap unknown errors
        oraError = UnknownError(underlying: error)
    }
    
    // Attempt recovery
    Task {
        let result = await RecoveryManager.shared.attemptRecovery(
            for: oraError,
            context: "orchestrator"
        )
        
        switch result {
        case .recovered:
            logger.info("Recovered from error")
            // Could retry the operation
            
        case .shouldRetry(let attempt, let max):
            logger.info("Retrying (\(attempt)/\(max))")
            // Retry logic here
            
        case .fallbackActivated(let mode):
            await FallbackManager.shared.activate(mode)
            ErrorPresenter.shared.present(oraError, in: .overlay)
            
        case .requiresUserAction(let action):
            ErrorPresenter.shared.present(oraError, in: .overlay)
            // Show action button
            
        case .maxRetriesExceeded, .recoveryFailed, .aborted:
            ErrorPresenter.shared.present(oraError, in: .overlay)
            transition(to: .error(oraError.userMessage))
        }
    }
}

// Unknown error wrapper
struct UnknownError: OraError {
    let underlying: Error
    
    var category: ErrorCategory { .unknown }
    var isRecoverable: Bool { false }
    var recoveryStrategy: RecoveryStrategy { .abort }
    var userMessage: String { "An unexpected error occurred. Please try again." }
    var technicalDetails: String { underlying.localizedDescription }
    var errorDescription: String? { userMessage }
}
```

---

## 5. Graceful Degradation Matrix

| Component Failed | Fallback Behavior | User Experience |
|:-----------------|:------------------|:----------------|
| **TTS** | Text-only mode | Response shown in overlay, no audio |
| **LLM** | Dictation-only mode | ASR works, no AI processing |
| **ASR** | Manual text input | Type in overlay (future feature) |
| **Calendar Tool** | Skip calendar actions | "I can't access your calendar right now" |
| **All AI** | Informational mode | App remains stable, shows status |

---

## 6. Acceptance Criteria

### Error Handling

- [ ] **AC-1:** All component errors mapped to OraError types
- [ ] **AC-2:** User-friendly messages for all error types
- [ ] **AC-3:** Technical details logged for debugging

### Recovery

- [ ] **AC-4:** Transient errors retried with backoff
- [ ] **AC-5:** OOM triggers memory cleanup and retry
- [ ] **AC-6:** Model reload attempted for engine crashes
- [ ] **AC-7:** Retry counts reset on success

### Fallbacks

- [ ] **AC-8:** TTS failure → text-only mode
- [ ] **AC-9:** LLM failure → dictation-only mode
- [ ] **AC-10:** Fallback status shown in UI
- [ ] **AC-11:** Fallbacks can be deactivated when recovered

### User Experience

- [ ] **AC-12:** No unhandled crashes during operation
- [ ] **AC-13:** Error rate limiting prevents spam
- [ ] **AC-14:** Actionable errors show recovery options
- [ ] **AC-15:** All errors logged to audit trail

---

## 7. Test Cases

```swift
// ErrorRecoveryTests.swift

import XCTest
@testable import Ora

final class ErrorRecoveryTests: XCTestCase {
    
    // TC-1: Transient errors trigger retry
    func test_transientError_triggersRetry() async {
        let error = ASRError.engineTimeout
        
        let result = await RecoveryManager.shared.attemptRecovery(
            for: error,
            context: "test"
        )
        
        if case .shouldRetry(let attempt, let max) = result {
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(max, 2)
        } else {
            XCTFail("Expected retry result")
        }
    }
    
    // TC-2: Max retries exceeded returns failure
    func test_maxRetriesExceeded_returnsFailure() async {
        let error = ASRError.engineTimeout
        
        // Exhaust retries
        _ = await RecoveryManager.shared.attemptRecovery(for: error, context: "test2")
        _ = await RecoveryManager.shared.attemptRecovery(for: error, context: "test2")
        let result = await RecoveryManager.shared.attemptRecovery(for: error, context: "test2")
        
        if case .maxRetriesExceeded = result {
            // Expected
        } else {
            XCTFail("Expected maxRetriesExceeded")
        }
    }
    
    // TC-3: Permission error requires user action
    func test_permissionError_requiresUserAction() async {
        let error = ASRError.microphoneDenied
        
        let result = await RecoveryManager.shared.attemptRecovery(
            for: error,
            context: "test"
        )
        
        if case .requiresUserAction(let action) = result {
            XCTAssertEqual(action, .grantPermission)
        } else {
            XCTFail("Expected requiresUserAction")
        }
    }
    
    // TC-4: TTS error activates text-only fallback
    @MainActor
    func test_ttsError_activatesTextOnlyFallback() async {
        FallbackManager.shared.reset()
        
        let error = TTSError.engineCrash(underlying: nil)
        _ = await RecoveryManager.shared.attemptRecovery(for: error, context: "test")
        
        // Fallback should be activated by orchestrator integration
        // This test verifies the strategy
        XCTAssertEqual(error.recoveryStrategy, .fallback(.textOnly))
    }
}
```

---

## 8. Directory Structure

```
Ora/
└── Reliability/
    ├── OraError.swift
    ├── RecoveryManager.swift
    ├── FallbackManager.swift
    └── ErrorPresenter.swift
```

---

## 9. Implementation Checklist

- [ ] Create `OraError.swift` with all error types
- [ ] Create `RecoveryManager.swift`
- [ ] Create `FallbackManager.swift`
- [ ] Create `ErrorPresenter.swift`
- [ ] Integrate with ConversationOrchestrator
- [ ] Add fallback status to overlay UI
- [ ] Add error logging to AuditLogger
- [ ] Test recovery flows
- [ ] Test fallback activation/deactivation
- [ ] Test error rate limiting
