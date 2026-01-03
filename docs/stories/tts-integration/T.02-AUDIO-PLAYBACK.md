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

- [x] **AC-1:** AVAudioEngine configured for playback - ✅ `prepare()` sets up engine with 24kHz mono format
- [x] **AC-2:** Chunks scheduled as they arrive - ✅ `play()` iterates stream and schedules buffers via `playerNode.scheduleBuffer()`
- [x] **AC-3:** Jitter buffer prevents underruns - ✅ 800ms target buffer with throttling when > 1.6s buffered
- [x] **AC-4:** `stop()` clears queue immediately - ✅ `playerNode.stop()` clears scheduled buffers
- [x] **AC-5:** Waits for completion before returning - ✅ `waitForPlaybackComplete()` polls until buffer drained
- [x] **AC-6:** Service is thread-safe (actor isolation) - ✅ `AudioPlaybackService` is an actor
- [x] **AC-7:** Handles empty chunks gracefully (marker chunks from fallback) - ✅ `guard !chunk.isEmpty else { continue }`
- [x] **AC-8:** Error handling for unprepared state - ✅ Throws `AudioPlaybackError.notPrepared`

---

## 7. Verification Plan

### Automated Tests

- [x] `test_prepareInitializesEngine` - Verify prepare() sets up AVAudioEngine
- [x] `test_prepareIsIdempotent` - Verify multiple prepare() calls succeed
- [x] `test_isPrepared_falseInitially` - Verify initial state is unprepared
- [x] `test_playStreamsChunks` - Verify chunks are scheduled for playback
- [x] `test_stopClearsQueue` - Verify stop() clears pending audio
- [x] `test_playEmptyChunksSkipped` - Verify empty marker chunks are handled
- [x] `test_playThrowsWhenNotPrepared` - Verify proper error for unprepared state
- [x] `test_shutdownCleansUp` - Verify shutdown() releases resources
- [x] `test_audioPlaybackError_descriptions` - Verify error descriptions
- [x] `test_playingState_duringPlayback` - Verify state tracking during playback

### Manual Tests

- [ ] Build and run app with Kokoro model downloaded
- [ ] Trigger TTS and verify audio plays smoothly
- [ ] Stop TTS mid-playback and verify clean stop
- [ ] Start multiple TTS requests and verify no audio artifacts

---

## 8. Implementation Checklist

- [x] Create `AudioPlaybackService.swift`
- [x] Create `AudioPlaybackServiceTests.swift`
- [x] Test streaming playback
- [x] Test interruption handling
- [x] Build and run tests

---

## Implementation Summary

**Date:** 2026-01-03
**Branch:** `feat/t.02-audio-playback`
**Commits:** 1

### Files Created
- `Ora/TTS/AudioPlaybackService.swift` - Audio playback actor with:
  - AVAudioEngine + AVAudioPlayerNode configuration
  - Streaming playback from AsyncThrowingStream<AudioChunk, Error>
  - 800ms jitter buffer with throttling
  - Immediate stop() with queue clearing
  - Proper shutdown() for engine cleanup
- `OraTests/AudioPlaybackServiceTests.swift` - 10 unit tests covering:
  - Engine preparation and idempotency
  - Streaming playback
  - Stop/shutdown behavior
  - Error handling
  - State tracking

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests implemented (10 tests)
- [x] Build succeeded
