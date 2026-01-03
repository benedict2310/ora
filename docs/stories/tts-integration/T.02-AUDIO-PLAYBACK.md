# T.02 - Audio Playback

**Epic:** TTS Integration
**Status:** In Progress
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** T.01 (TTS Service)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Create an `AudioPlaybackService` that manages streaming audio playback with buffering and clean interruption. This service receives `AudioChunk`s from `TTSService` and plays them through the system audio output using `AVAudioEngine`.

---

## 2. User Story

As a user, I want Ora's spoken responses to play smoothly through my speakers without stuttering or delays, and I want to be able to interrupt playback at any time.

---

## 3. Scope

### In Scope

- `AudioPlaybackService` actor wrapping `AVAudioEngine` for playback
- Streaming playback of `AudioChunk` data via `AVAudioPlayerNode`
- Jitter buffer (~800ms) to prevent audio underruns
- Immediate stop with queue clearing
- Proper waiting for playback completion before returning
- Actor isolation for thread safety

### Out of Scope

- Sentence chunking for early playback (T.03)
- Volume controls (future enhancement)
- Audio device selection (future enhancement)
- Ducking other audio sources (future enhancement)

---

## 4. Architecture Alignment

- **Component Boundary:** AudioPlaybackService is isolated from TTSService; receives AudioChunks, plays audio
- **Concurrency Model:** `AudioPlaybackService` is an actor; playback runs on audio render thread
- **Pipeline Integration:** TTSService → AudioPlaybackService → speakers
- **PRD Reference:** Section 5 (TTS targets ~500ms to first audio for short responses)
- **Architecture Reference:** Section 1 Component Diagram - TTSEngine outputs to audio playback

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/TTS/AudioPlaybackService.swift` - Main audio playback actor with AVAudioEngine

### 5.2 Files to Modify

- None

### 5.3 Tests to Add

- `OraTests/AudioPlaybackServiceTests.swift` - Unit tests for playback service
  - Test `prepare()` initializes engine
  - Test `play()` streams audio chunks
  - Test `stop()` clears queue immediately
  - Test playback completion waiting

---

## 6. Acceptance Criteria

- [ ] **AC-1:** AVAudioEngine configured for playback
- [ ] **AC-2:** Chunks scheduled as they arrive
- [ ] **AC-3:** Jitter buffer prevents underruns
- [ ] **AC-4:** `stop()` clears queue immediately
- [ ] **AC-5:** Waits for completion before returning
- [ ] **AC-6:** Service is thread-safe (actor isolation)
- [ ] **AC-7:** Handles empty chunks gracefully (marker chunks from fallback)
- [ ] **AC-8:** Error handling for unprepared state

---

## 7. Verification Plan

### Automated Tests

- [ ] `test_prepareInitializesEngine` - Verify prepare() sets up AVAudioEngine
- [ ] `test_playStreamsChunks` - Verify chunks are scheduled for playback
- [ ] `test_stopClearsQueue` - Verify stop() clears pending audio
- [ ] `test_playEmptyChunksSkipped` - Verify empty marker chunks are handled
- [ ] `test_playThrowsWhenNotPrepared` - Verify proper error for unprepared state
- [ ] `test_isPreparedReturnsCorrectState` - Verify state tracking

### Manual Tests

- [ ] Build and run app with Kokoro model downloaded
- [ ] Trigger TTS and verify audio plays smoothly
- [ ] Stop TTS mid-playback and verify clean stop
- [ ] Start multiple TTS requests and verify no audio artifacts

---

## 8. Implementation Checklist

- [ ] Create `AudioPlaybackService.swift`
- [ ] Create `AudioPlaybackServiceTests.swift`
- [ ] Test streaming playback
- [ ] Test interruption handling
- [ ] Build and run tests
