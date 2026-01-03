# O.03 - Conversation Orchestrator

**Epic:** Orchestration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1-2 days
**Dependencies:** O.02 (Agent Loop), T.01 (TTS Service), T.02 (Audio Playback)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Extend the pipeline controller to coordinate the complete voice assistant flow including TTS:
- Hotkey → Audio capture → ASR transcription
- Transcription → Agent loop reasoning
- **Agent response → TTS playback → UI updates** ← This is the gap

This story bridges the existing `SimplePipelineController` with TTS output.

---

## 2. Current State Analysis

### What Exists

| Component | File | Status |
|-----------|------|--------|
| SimplePipelineController | `Ora/Orchestration/SimplePipelineController.swift` | Working, no TTS |
| PipelineState | `Ora/Orchestration/PipelineState.swift` | Has `awaitingFollowUp` |
| TTSService | `Ora/TTS/TTSService.swift` | Working (Kokoro + AVSpeech fallback) |
| AudioPlaybackService | `Ora/TTS/AudioPlaybackService.swift` | Working |
| OverlayMode | `Ora/Overlay/OverlayState.swift` | Has all needed states |
| ToolProposal | `Ora/Overlay/OverlayState.swift` | Already defined |
| AgentLoop | `Ora/Orchestration/AgentLoop.swift` | Working |

### Current Flow (SimplePipelineController)

```
Hotkey tap → listening → ASR → thinking → LLM → responding → awaitingFollowUp
                                                      ↓
                                          UI shows text (no audio!)
```

### Target Flow (After O.03)

```
Hotkey tap → listening → ASR → thinking → LLM → responding → speaking → awaitingFollowUp
                                                      ↓            ↓
                                          UI shows text    TTS plays audio
```

### Design Decision: Extend vs Replace

**Recommendation: Extend `SimplePipelineController`** rather than create a new `ConversationOrchestrator`.

Rationale:
- SimplePipelineController already handles hotkey, ASR, LLM, overlay, tap-to-talk flow
- Only missing piece is calling TTSService after LLM response
- Creating a parallel orchestrator risks code duplication and divergence
- Simpler to add TTS to existing working code

---

## 3. Existing API Reference

### TTSService (actor)

```swift
// Location: Ora/TTS/TTSService.swift

public actor TTSService {
    public static let shared = TTSService()

    /// Prepare TTS engine (call at startup)
    public func prepare() async throws

    /// Generate speech - returns stream of AudioChunks
    nonisolated public func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>

    /// Stop current speech
    public func stop() async

    /// Check if speaking
    public var speaking: Bool

    /// Check if Kokoro is ready (vs fallback)
    public var kokoroAvailable: Bool
}
```

### AudioPlaybackService (actor)

```swift
// Location: Ora/TTS/AudioPlaybackService.swift

public actor AudioPlaybackService {
    public static let shared = AudioPlaybackService()

    /// Prepare audio engine (call at startup)
    public func prepare() throws

    /// Play audio chunks from TTS stream
    public func play(chunks: AsyncThrowingStream<AudioChunk, Error>) async throws

    /// Stop playback immediately
    public func stop()

    /// Check if prepared
    public var isPrepared: Bool

    /// Check if playing
    public var playing: Bool
}
```

### OverlayMode (existing)

```swift
// Location: Ora/Overlay/OverlayState.swift

enum OverlayMode: Equatable, Sendable {
    case hidden
    case listening
    case thinking
    case responding       // ← Use for both text streaming AND speaking
    case awaitingFollowUp
    case proposing(ToolProposal)
    case executing
    case completed
    case error(String)
}
```

### PipelineState (existing)

```swift
// Location: Ora/Orchestration/PipelineState.swift

enum PipelineState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case responding
    case awaitingFollowUp  // ← Current terminal state
    case completed
    case error(String)
}
```

---

## 4. Implementation

### 4.1 Add Speaking State to PipelineState

**File:** `Ora/Orchestration/PipelineState.swift`

```swift
enum PipelineState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case responding
    case speaking          // ← ADD: TTS playback in progress
    case awaitingFollowUp
    case completed
    case error(String)

    var description: String {
        switch self {
        // ... existing cases ...
        case .speaking: return "Speaking..."
        }
    }

    var canStartListening: Bool {
        switch self {
        case .idle, .completed, .error, .awaitingFollowUp:
            return true
        case .listening, .thinking, .responding, .speaking:
            return false
        }
    }
}
```

### 4.2 Add TTS to SimplePipelineController

**File:** `Ora/Orchestration/SimplePipelineController.swift`

Add TTS task property:
```swift
private var ttsTask: Task<Void, Never>?
```

Add TTS preparation at startup (in `startListening` or app init):
```swift
// Prepare TTS engine if not ready
Task {
    do {
        try await AudioPlaybackService.shared.prepare()
    } catch {
        logger.warning("Failed to prepare audio playback: \(error)")
    }
}
```

Replace `handleCompletion()` with TTS-enabled version:
```swift
private func handleCompletion() {
    self.logger.info("Response complete, starting TTS: \(self.currentResponse.prefix(50))...")

    // Start TTS playback
    self.speakResponse(self.currentResponse)
}

private func speakResponse(_ text: String) {
    self.transition(to: .speaking)
    // Keep overlay in responding mode during speech
    // OverlayWindowController.shared.mode = .responding  // Already set

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
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self.state == .awaitingFollowUp else { return }
            await MainActor.run {
                self.startFollowUp()
            }
        }
    }
}
```

Update `cancel()` to stop TTS:
```swift
func cancel() {
    // ... existing cancellation code ...

    // Cancel TTS
    self.ttsTask?.cancel()
    self.ttsTask = nil

    // Stop TTS playback
    Task {
        await TTSService.shared.stop()
        await AudioPlaybackService.shared.stop()
        await AudioService.shared.cancel()
    }

    // ... rest of cancel ...
}
```

Update status bar mapping for `.speaking`:
```swift
private func updateStatusBar(for state: PipelineState) {
    switch state {
    case .idle, .completed:
        StatusBarController.shared?.setState(.idle)
    case .listening:
        StatusBarController.shared?.setState(.listening)
    case .thinking, .responding:
        StatusBarController.shared?.setState(.thinking)
    case .speaking:
        StatusBarController.shared?.setState(.speaking)
    case .awaitingFollowUp:
        StatusBarController.shared?.setState(.thinking)
    case .error(let message):
        StatusBarController.shared?.setState(.error(message))
    }
}
```

### 4.3 Prepare TTS at App Startup

**File:** `Ora/AppDelegate.swift`

In `applicationDidFinishLaunching` or similar:
```swift
// Prepare TTS engine for faster first response
Task {
    do {
        try await TTSService.shared.prepare()
        try await AudioPlaybackService.shared.prepare()
    } catch {
        Logger(subsystem: "com.ora.app", category: "AppDelegate")
            .warning("TTS preparation failed: \(error)")
    }
}
```

---

## 5. State Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      SimplePipelineController                            │
│                          (with TTS)                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────┐  hotkey   ┌───────────┐  ASR done  ┌──────────┐               │
│  │ idle │ ────────► │ listening │ ─────────► │ thinking │               │
│  └──┬───┘           └─────┬─────┘            └────┬─────┘               │
│     │                     │                       │                      │
│     │                   cancel                    │                      │
│     │◄────────────────────┘                       │                      │
│     │                                             │                      │
│     │                                             ▼                      │
│     │                                      ┌────────────┐                │
│     │                                      │ responding │ LLM streaming  │
│     │                                      └─────┬──────┘                │
│     │                                            │                       │
│     │                                            ▼                       │
│     │                                      ┌────────────┐                │
│     │                                      │  speaking  │ TTS playback   │
│     │                                      └─────┬──────┘                │
│     │                                            │                       │
│     │     ┌──────────────────────────────────────┘                       │
│     │     │                                                              │
│     │     ▼                                                              │
│     │  ┌─────────────────┐                                               │
│     │  │ awaitingFollowUp│◄───────┐                                     │
│     │  └────────┬────────┘        │                                      │
│     │           │                 │                                      │
│     │    follow-up tap       auto-listen                                │
│     │           │                 │                                      │
│     │           ▼                 │                                      │
│     │      ┌───────────┐          │                                      │
│     │      │ listening │──────────┘                                      │
│     │      └───────────┘                                                 │
│     │                                                                    │
│     │◄───────────── cancel / dismiss ────────────────────────────────────│
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Acceptance Criteria

### TTS Integration

- [ ] **AC-1:** LLM response triggers TTS playback
- [ ] **AC-2:** Audio plays through system speakers
- [ ] **AC-3:** Fallback to AVSpeechSynthesizer if Kokoro unavailable
- [ ] **AC-4:** State transitions to `.speaking` during playback
- [ ] **AC-5:** State transitions to `.awaitingFollowUp` after playback completes

### Pipeline Flow

- [ ] **AC-6:** Full flow works: hotkey → ASR → LLM → TTS → audio output
- [ ] **AC-7:** Overlay shows response text during TTS playback
- [ ] **AC-8:** Status bar shows speaking indicator during playback

### Cancellation

- [ ] **AC-9:** Cancel stops TTS playback immediately
- [ ] **AC-10:** Pressing hotkey during speaking cancels and starts new session
- [ ] **AC-11:** TTS errors don't block completion (graceful degradation)

### Error Handling

- [ ] **AC-12:** TTS failure logs error but completes normally
- [ ] **AC-13:** Audio engine failure falls back gracefully
- [ ] **AC-14:** No crash on rapid cancel/restart

### Performance

- [ ] **AC-15:** TTS starts within 500ms of LLM completion (after warmup)
- [ ] **AC-16:** No audio glitches during normal playback

---

## 7. Test Cases

```swift
// SimplePipelineControllerTTSTests.swift

import XCTest
@testable import Ora

@MainActor
final class SimplePipelineControllerTTSTests: XCTestCase {

    var controller: SimplePipelineController!

    override func setUp() async throws {
        controller = SimplePipelineController.makeTestInstance()
    }

    // TC-1: Speaking state exists
    func test_speakingState_exists() {
        XCTAssertEqual(PipelineState.speaking.description, "Speaking...")
    }

    // TC-2: Speaking state cannot start listening
    func test_speakingState_cannotStartListening() {
        XCTAssertFalse(PipelineState.speaking.canStartListening)
    }

    // TC-3: Cancel during speaking stops TTS
    func test_cancel_duringSpeaking_stopsTTS() async {
        // This would require mocking TTSService
        // Verify that cancel() calls TTSService.shared.stop()
    }

    // TC-4: TTS error completes gracefully
    func test_ttsError_completesGracefully() async {
        // Simulate TTS error and verify state transitions to awaitingFollowUp
    }
}

// AudioPlaybackServiceTests.swift additions
@MainActor
final class AudioPlaybackIntegrationTests: XCTestCase {

    // TC-5: Playback service can be prepared
    func test_prepare_succeeds() async throws {
        let service = AudioPlaybackService.shared
        try await service.prepare()
        XCTAssertTrue(service.isPrepared)
    }
}
```

---

## 8. Implementation Checklist

### Phase 1: State Updates
- [ ] Add `.speaking` case to `PipelineState`
- [ ] Update `canStartListening` for speaking state
- [ ] Update status bar mapping for speaking state

### Phase 2: TTS Integration
- [ ] Add `ttsTask` property to SimplePipelineController
- [ ] Implement `speakResponse(_:)` method
- [ ] Implement `finishSpeaking()` method
- [ ] Update `handleCompletion()` to call TTS

### Phase 3: Lifecycle
- [ ] Update `cancel()` to stop TTS
- [ ] Add TTS preparation to app startup
- [ ] Ensure AudioPlaybackService prepared before use

### Phase 4: Testing
- [ ] Manual test: full flow with audio output
- [ ] Manual test: cancel during speaking
- [ ] Manual test: multiple rapid sessions
- [ ] Add unit tests for new states

### Phase 5: Cleanup
- [ ] Update story status in README
- [ ] Remove any dead code

---

## 9. Notes

### Kokoro vs AVSpeech Fallback

TTSService automatically falls back to AVSpeechSynthesizer if Kokoro model isn't available. The integration code doesn't need to handle this - it's transparent.

### Audio Session Management

AudioPlaybackService manages the AVAudioEngine. It should be prepared once at startup and reused. The service handles buffer management and jitter prevention internally.

### Streaming TTS (Future - T.03)

This story uses complete-response TTS. T.03 (Sentence Chunker) will add streaming TTS where audio starts playing before the full LLM response is complete. The current implementation is compatible with this future enhancement.

### Multi-turn Conversations

The existing `awaitingFollowUp` state and auto-listen feature work unchanged. TTS simply inserts a `.speaking` phase between `.responding` and `.awaitingFollowUp`.
