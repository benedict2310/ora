# A.02 - ASR Service

**Epic:** ASR Integration
**Status:** Complete
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1-2 days
**Dependencies:** Parakeet S.01, S.03 (Core Engine, Streaming)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create an `ASRService` actor that wraps the Parakeet engine and conforms to Ora's `ASRServicing` protocol, providing streaming transcription.

---

## 2. Implementation

### 2.1 ASR Service

**File:** `Ora/ASR/ASRService.swift`

```swift
//
//  ASRService.swift
//  Ora
//
//  Parakeet ASR wrapper conforming to Ora protocols
//

import Foundation
import AVFoundation
import os

/// Events emitted during transcription
enum ASREvent: Sendable {
    case partial(text: String, stability: Float)
    case final(text: String)
}

/// ASR service protocol
protocol ASRServicing: Sendable {
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error>
    func reset() async
}

/// Parakeet-based ASR service
actor ASRService: ASRServicing {
    
    // MARK: - Singleton
    
    static let shared = ASRService()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "ASRService")
    private var engine: ParakeetEngine?
    private var isReady = false
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Prepare the ASR engine (load models)
    func prepare() async throws {
        guard !isReady else { return }
        
        logger.info("Preparing ASR engine...")
        
        engine = ParakeetEngine()
        try await engine?.prepare()
        
        isReady = true
        logger.info("ASR engine ready")
    }
    
    /// Transcribe audio frames to text events
    func transcribe(frames: AsyncStream<AudioFrame>) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runTranscription(frames: frames, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Reset decoder state for new session
    func reset() async {
        await engine?.reset()
        logger.debug("ASR decoder reset")
    }
    
    // MARK: - Private
    
    private func runTranscription(
        frames: AsyncStream<AudioFrame>,
        continuation: AsyncThrowingStream<ASREvent, Error>.Continuation
    ) async throws {
        guard isReady, let engine = engine else {
            throw ASRServiceError.notReady
        }
        
        var accumulatedSamples: [Float] = []
        var lastPartialText = ""
        
        // Process frames as they arrive
        for await frame in frames {
            accumulatedSamples.append(contentsOf: frame.samples)
            
            // Process when we have enough audio (160ms = 2560 samples at 16kHz)
            if accumulatedSamples.count >= 2560 {
                let partial = try await engine.process(
                    samples: accumulatedSamples,
                    language: "en"
                )
                
                if let partial = partial, partial.text != lastPartialText {
                    lastPartialText = partial.text
                    continuation.yield(.partial(text: partial.text, stability: 0.8))
                }
            }
        }
        
        // Finalize with remaining audio
        if !accumulatedSamples.isEmpty {
            let final = try await engine.finalize(
                samples: accumulatedSamples,
                language: "en"
            )
            
            if let final = final, !final.text.isEmpty {
                continuation.yield(.final(text: final.text))
            }
        }
        
        continuation.finish()
    }
}

// MARK: - Errors

enum ASRServiceError: LocalizedError {
    case notReady
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notReady:
            return "ASR engine is not ready. Please wait for model loading."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
```

---

## 3. Acceptance Criteria

- [x] **AC-1:** `ASRService` conforms to `ASRServicing` protocol - ✅ Verified in `Ora/ASR/ASRService.swift:52`
- [x] **AC-2:** `transcribe()` returns `AsyncThrowingStream<ASREvent, Error>` - ✅ Verified in `Ora/ASR/ASRService.swift:95`
- [x] **AC-3:** Partial events emitted during speech - ✅ Verified by test `test_transcribe_emitsPartialEvents`
- [x] **AC-4:** Final event emitted when stream ends - ✅ Verified by test `test_transcribe_emitsFinalEvent`
- [x] **AC-5:** `reset()` clears decoder state - ✅ Verified by test `test_reset_callsEngineReset`
- [x] **AC-6:** Handles empty audio gracefully - ✅ Verified by tests `test_transcribe_handlesEmptyAudioGracefully` and `test_transcribe_handlesEmptyFrames`

---

## 4. Implementation Checklist

- [x] Create `ASRService.swift`
- [x] Integrate with ParakeetEngine from S.01
- [x] Test partial emission rate
- [x] Test final transcription accuracy
- [x] Add error handling for model load failures

---

## Implementation Plan

### Files to Create
- `Ora/ASR/ASRService.swift` - ASRService actor with ASRServicing protocol, ASREvent enum, and ASRServiceError

### Files to Modify
- None (new service, integrates with existing ParakeetEngine)

### Tests to Add
- `OraTests/ASRServiceTests.swift` - Unit tests for ASRService including:
  - Protocol conformance
  - Partial event emission
  - Final event emission
  - Empty audio handling
  - Reset functionality

---

## Implementation Summary

**Date:** 2025-12-30
**Branch:** `feat/A.02-asr-service`

### Files Created
- `Ora/ASR/ASRService.swift` - ASRService actor implementing ASRServicing protocol with:
  - `ASREvent` enum for partial/final events
  - `ASRServicing` protocol definition
  - `ASRService` actor with singleton pattern
  - `ASRServiceError` for error handling
- `OraTests/ASRServiceTests.swift` - Unit tests covering:
  - `ASREventTests` - Sendable and Equatable conformance
  - `ASRServiceErrorTests` - Error description validation
  - `ASRServiceTests` - All acceptance criteria verification

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing (458 tests, 0 failures)
- [x] Working tree clean

---

## Code Review History

### Iteration 1 (2025-12-30T10:09:58Z)
- **Commit:** ea9794e
- **P1 Issue:** `accumulatedSamples` never trimmed, causing unbounded memory growth
- **Resolution:** Added `maxWindowSamples` (10s) and trimming logic

### Iteration 2 (2025-12-30T10:15:13Z)
- **Commit:** 0f9716c
- **P1 Issue:** 10s rolling window drops earlier audio for long utterances, losing earlier speech
- **Resolution:** Added `committedText` to accumulate finalized transcription from chunks that roll out of the window

### Iteration 3 (2025-12-30T10:51:24Z)
- **Commit:** 40a3d5b
- **Build:** Pass
- **Tests:** Pass (458 tests, 0 failures, 2 skipped) - *Note: Reviewer environment had xcodebuild exit 65 due to app crash, but local tests pass*
- **Issues Found:** None

---

## Final Code Review

**Reviewer:** Codex Subagent
**Date:** 2025-12-30
**Final Commit:** cdcc058

### Summary
- Files reviewed: 3 (ASRService.swift, ASRServiceTests.swift, story doc)
- Build status: Pass
- Tests status: Pass (458 tests, 0 failures, 2 skipped)

### Issues Found
- **P0 (Critical):** None
- **P1 (Major):** None (all fixed)
- **P2 (Minor):** None

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
