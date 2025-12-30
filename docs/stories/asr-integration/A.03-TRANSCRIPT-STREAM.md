# A.03 - Transcript Stream

**Epic:** ASR Integration
**Status:** In Progress
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** A.01 (Audio Service), A.02 (ASR Service), F.07 (Overlay)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Liquid Glass UI Guide](../../references/liquid-glass-ui.md)

---

## 1. Objective

Connect the audio and ASR services to the overlay UI, streaming partial transcripts in real-time and delivering final transcripts to the orchestrator.

---

## 2. Implementation

### 2.1 Transcript Coordinator

**File:** `Ora/ASR/TranscriptCoordinator.swift`

```swift
//
//  TranscriptCoordinator.swift
//  Ora
//
//  Coordinates audio capture, ASR, and UI updates
//

import Foundation
import os

/// Coordinates the transcription pipeline
actor TranscriptCoordinator {
    
    // MARK: - Singleton
    
    static let shared = TranscriptCoordinator()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "TranscriptCoordinator")
    
    private var currentTask: Task<String?, Error>?
    private var finalTranscript: String?
    
    // MARK: - Public API
    
    /// Start transcription session
    /// Returns the final transcript when complete
    func startSession() async throws -> String? {
        // Cancel any existing session
        currentTask?.cancel()
        
        // Reset ASR state
        await ASRService.shared.reset()
        
        // Start new session
        currentTask = Task {
            try await runSession()
        }
        
        return try await currentTask?.value
    }
    
    /// Cancel current session
    func cancelSession() {
        currentTask?.cancel()
        currentTask = nil
        
        Task {
            await AudioService.shared.cancel()
        }
        
        logger.debug("Session cancelled")
    }
    
    // MARK: - Private
    
    private func runSession() async throws -> String? {
        logger.info("Starting transcription session")
        
        // Start audio capture
        let audioStream = try await AudioService.shared.start()
        
        // Start transcription
        let asrStream = ASRService.shared.transcribe(frames: audioStream)
        
        var lastText = ""
        
        // Process ASR events
        for try await event in asrStream {
            try Task.checkCancellation()
            
            switch event {
            case .partial(let text, _):
                lastText = text
                await updateUI(text: text, isPartial: true)
                
            case .final(let text):
                lastText = text
                await updateUI(text: text, isPartial: false)
            }
        }
        
        logger.info("Transcription complete: \(lastText.prefix(50))...")
        return lastText.isEmpty ? nil : lastText
    }
    
    private func updateUI(text: String, isPartial: Bool) async {
        await MainActor.run {
            OverlayWindowController.shared.model.addUserMessage(text, isPartial: isPartial)
        }
    }
}
```

---

## 3. Acceptance Criteria

- [ ] **AC-1:** `startSession()` starts audio and ASR
- [ ] **AC-2:** Partial transcripts update overlay UI
- [ ] **AC-3:** Final transcript returned when hotkey released
- [ ] **AC-4:** `cancelSession()` stops all processing
- [ ] **AC-5:** UI shows "Listening..." indicator during partials

---

## 4. Implementation Checklist

- [ ] Create `TranscriptCoordinator.swift`
- [ ] Wire up to overlay view model
- [ ] Test end-to-end flow
- [ ] Add cancellation handling
- [ ] Test with various speech patterns

---

## Implementation Plan

**Date Started:** 2025-12-30
**Branch:** `feat/A.03-transcript-stream`

### Files to Create
- `Ora/ASR/TranscriptCoordinator.swift` - Coordinates audio→ASR→UI pipeline

### Files to Modify
- None required (uses existing APIs from A.01/A.02/F.07)

### Tests to Add
- `OraTests/TranscriptCoordinatorTests.swift` - Unit tests for coordinator

### Implementation Notes
- Uses existing `AudioService.shared.start()` returning `AsyncStream<AudioFrame>`
- Uses existing `ASRService.shared.transcribe(frames:)` returning `AsyncThrowingStream<ASREvent, Error>`
- Uses existing `OverlayWindowController.shared.model.addUserMessage(_:isPartial:)`
- Story spec provides nearly complete implementation code

---

## Progress Log

### Step 1: Created Branch ✅
- Created `feat/A.03-transcript-stream` from main

### Step 2: Created TranscriptCoordinator ✅
- Created `Ora/ASR/TranscriptCoordinator.swift`
- Actor-based coordinator with:
  - `startSession()` - starts audio & ASR, returns final transcript
  - `cancelSession()` - cancels current session
  - Streams partials to OverlayViewModel via `addUserMessage`

### Step 3: Created Tests ✅
- Created `OraTests/TranscriptCoordinatorTests.swift`
- Tests for: shared instance, cancel behavior, session lifecycle
