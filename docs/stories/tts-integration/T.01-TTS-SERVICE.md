# T.01 - TTS Service

**Epic:** TTS Integration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2 days
**Dependencies:** F.03 (Model Manager)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [kokoro-swift-mlx](https://github.com/mattmireles/kokoro-swift-mlx)

---

## 1. Objective

Enable Ora to speak responses aloud by wrapping Kokoro MLX for local text-to-speech synthesis. This provides the voice output stage of the pipeline (ASR → LLM → **TTS**), giving users audible feedback without any cloud dependencies.

## 2. User Story

As a user, I want Ora to speak its responses so that I can hear answers hands-free and continue my workflow without looking at the screen.

## 3. Scope

### In Scope

- `TTSService` actor wrapping Kokoro MLX for audio generation
- `TTSServicing` protocol for testability and future TTS backends
- `AudioChunk` type for streaming PCM audio output
- Model loading via `ModelManager.pathForModel(.kokoro)`
- Graceful fallback to `AVSpeechSynthesizer` when Kokoro fails
- Cancellation support via `stop()` method
- Logging for TTS lifecycle events

### Out of Scope

- Audio playback/queueing (T.02 - Audio Playback)
- Sentence chunking for early playback (T.03 - Sentence Chunker)
- Voice selection UI (future enhancement)
- Multiple voice profiles (future enhancement)

## 4. Architecture Alignment

- **Component Boundary:** TTS is isolated from LLM and UI; receives plain text, emits audio chunks
- **Concurrency Model:** `TTSService` is an actor; synthesis runs on background thread; audio chunks are `Sendable`
- **Pipeline Integration:** TTSService → AudioPlayback (T.02) → speakers
- **Fallback Path:** Kokoro failure → AVSpeechSynthesizer (plays directly, not via AudioChunk)
- **PRD Reference:** Section 5 (TTS targets ~500ms to first audio for short responses)
- **Architecture Reference:** Section 1 Component Diagram - TTSEngine actor

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/TTS/TTSService.swift` - Main TTS actor with Kokoro integration and AVSpeech fallback
- `Ora/TTS/AudioChunk.swift` - Audio data structure for streaming output
- `Ora/TTS/TTSServicing.swift` - Protocol for TTS service abstraction

### 5.2 Files to Modify

- `project.yml` - Add kokoro-swift-mlx package dependency

### 5.3 Tests to Add

- `OraTests/TTSServiceTests.swift` - Unit tests for TTS service
  - Test `speak()` returns AsyncThrowingStream
  - Test `stop()` cancels current synthesis
  - Test fallback triggers on Kokoro failure
  - Test AudioChunk properties (samples, sampleRate, duration)

### 5.4 Dependencies/Config

- Add Swift Package: `kokoro-swift-mlx` from `https://github.com/mattmireles/kokoro-swift-mlx`
- Kokoro model must be downloaded via ModelManager (handled by F.03/F.09)

## 6. Acceptance Criteria

- [ ] AC-1: `TTSService` loads Kokoro model from `ModelManager.pathForModel(.kokoro)`
- [ ] AC-2: `speak(_:)` returns an AsyncThrowingStream of AudioChunk
- [ ] AC-3: Audio chunks stream incrementally as Kokoro generates them
- [ ] AC-4: Fallback to `AVSpeechSynthesizer` when Kokoro initialization or synthesis fails
- [ ] AC-5: `stop()` cancels current synthesis and clears state
- [ ] AC-6: `AudioChunk.sampleRate` is 24000 Hz (Kokoro default)
- [ ] AC-7: `AudioChunk.duration` computed property returns correct duration
- [ ] AC-8: Service is thread-safe (actor isolation)

## 7. Verification Plan

### Automated Tests

- [ ] `test_speakReturnsAsyncStream` - Verify speak() returns a stream
- [ ] `test_stopCancelsSynthesis` - Verify stop() cancels in-flight work
- [ ] `test_fallbackOnKokoroFailure` - Verify AVSpeech fallback activates
- [ ] `test_audioChunkDuration` - Verify duration calculation is correct
- [ ] `test_sampleRateIs24kHz` - Verify sample rate matches Kokoro output

### Manual Tests

- [ ] Build and run app with Kokoro model downloaded
- [ ] Trigger TTS via pipeline and verify audio plays
- [ ] Remove Kokoro model and verify fallback works
- [ ] Stop TTS mid-synthesis and verify clean cancellation

## 8. Performance / Reliability Considerations

- **Time-to-first-audio target:** ~500ms for short responses (measured from text submission)
- **Memory:** Kokoro model (~500MB) should be loaded once and reused
- **Cancellation:** Must not leak tasks or audio buffers on stop()
- **Error recovery:** Kokoro failures should not crash; fallback must engage

## 9. Risks & Mitigations

- **Risk:** kokoro-swift-mlx package may have API differences from expectation
  - **Mitigation:** Review package API during implementation; adapt wrapper accordingly
- **Risk:** Kokoro model loading may be slow
  - **Mitigation:** Load model asynchronously in `prepare()` before first use
- **Risk:** AVSpeechSynthesizer fallback doesn't provide raw audio chunks
  - **Mitigation:** Fallback plays directly; emit empty chunk to signal playback started

## 10. Open Questions

- None currently - kokoro-swift-mlx API will be verified during implementation

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
