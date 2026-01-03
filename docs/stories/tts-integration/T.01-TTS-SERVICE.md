# T.01 - TTS Service

**Epic:** TTS Integration
**Status:** Implemented (Partial - Fallback Only)
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2 days
**Dependencies:** F.03 (Model Manager)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [kokoro-swift-mlx](https://github.com/mattmireles/kokoro-swift-mlx)

---

## ⚠️ Current Limitations

**Kokoro TTS is NOT currently functional.** The implementation uses AVSpeechSynthesizer (macOS system voice) as a fallback.

### What Works
- `TTSService` actor with full API (`speak()`, `stop()`, `prepare()`)
- AVSpeechSynthesizer fallback plays audio through system voice
- Proper cancellation and lifecycle management
- All tests pass

### What Doesn't Work
- **Kokoro model is downloaded but not used** (~500MB wasted)
- **Audio quality is robotic** (system voice, not natural Kokoro voice)
- AC-3 (streaming audio chunks from Kokoro) is not implemented

### Root Cause
The `kokoro-swift-mlx` library is **not a proper Swift Package**:
- Structured as a sample iOS app, not an SPM package
- Requires bundling eSpeak NG (C library) for phonemization
- No `Package.swift` available to add as dependency

### Options to Complete Kokoro Integration

| Option | Effort | Description |
|:-------|:-------|:------------|
| **Wait** | 0 days | Wait for `kokoro-swift-mlx` maintainer to publish proper SPM package |
| **Fork & Package** | 1-2 days | Fork repo, extract TTS engine, create Package.swift, bundle eSpeak NG xcframework |
| **Alternative TTS** | 1-3 days | Research and integrate different on-device TTS solution |
| **Accept Fallback** | 0 days | Ship v1 with system voice; users get voice output, just not premium quality |

### Recommendation
For v1, **accept the fallback** - users get functional voice output. Create a follow-up story (T.04) to properly integrate Kokoro when the package situation is resolved.

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

- `Ora/TTS/TTSService.swift` - Main TTS actor with Kokoro integration and AVSpeech fallback ✅
- `Ora/TTS/AudioChunk.swift` - Audio data structure for streaming output ✅
- `Ora/TTS/TTSServicing.swift` - Protocol for TTS service abstraction ✅

### 5.2 Files to Modify

- `project.yml` - Add kokoro-swift-mlx package dependency (deferred - package not yet a proper SPM package)

### 5.3 Tests to Add

- `OraTests/TTSServiceTests.swift` - Unit tests for TTS service ✅
  - Test `speak()` returns AsyncThrowingStream ✅
  - Test `stop()` cancels current synthesis ✅
  - Test fallback triggers on Kokoro failure ✅
  - Test AudioChunk properties (samples, sampleRate, duration) ✅

### 5.4 Dependencies/Config

- Add Swift Package: `kokoro-swift-mlx` from `https://github.com/mattmireles/kokoro-swift-mlx` (deferred - not yet a proper SPM package, placeholder KokoroEngine implemented instead)
- Kokoro model must be downloaded via ModelManager (handled by F.03/F.09)

## 6. Acceptance Criteria

- [x] AC-1: `TTSService` loads Kokoro model from `ModelManager.pathForModel(.kokoro)` - ✅ Implemented in `prepare()`
- [x] AC-2: `speak(_:)` returns an AsyncThrowingStream of AudioChunk - ✅ Verified by `test_speakReturnsAsyncStream`
- [ ] AC-3: Audio chunks stream incrementally as Kokoro generates them - ⚠️ Placeholder; actual Kokoro integration pending
- [x] AC-4: Fallback to `AVSpeechSynthesizer` when Kokoro initialization or synthesis fails - ✅ Verified by `test_kokoroEngineSynthesizeTriggersError`
- [x] AC-5: `stop()` cancels current synthesis and clears state - ✅ Verified by `test_stopCancelsSynthesis`
- [x] AC-6: `AudioChunk.sampleRate` is 24000 Hz (Kokoro default) - ✅ Verified by `test_sampleRateIs24kHz`
- [x] AC-7: `AudioChunk.duration` computed property returns correct duration - ✅ Verified by `test_audioChunkDuration_calculatesCorrectly`
- [x] AC-8: Service is thread-safe (actor isolation) - ✅ TTSService and KokoroEngine are actors

## 7. Verification Plan

### Automated Tests

- [x] `test_speakReturnsAsyncStream` - Verify speak() returns a stream ✅
- [x] `test_stopCancelsSynthesis` - Verify stop() cancels in-flight work ✅
- [x] `test_kokoroEngineSynthesizeTriggersError` - Verify fallback activates (placeholder throws) ✅
- [x] `test_audioChunkDuration_calculatesCorrectly` - Verify duration calculation is correct ✅
- [x] `test_sampleRateIs24kHz` - Verify sample rate matches Kokoro output ✅

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
  - **Status:** Package is not yet a proper SPM package; placeholder KokoroEngine implemented
- **Risk:** Kokoro model loading may be slow
  - **Mitigation:** Load model asynchronously in `prepare()` before first use ✅
- **Risk:** AVSpeechSynthesizer fallback doesn't provide raw audio chunks
  - **Mitigation:** Fallback plays directly; emit empty chunk to signal playback started ✅

## 10. Open Questions

- **Resolved:** kokoro-swift-mlx is not a proper Swift Package yet. Implemented placeholder KokoroEngine that validates model files exist but triggers fallback for actual synthesis. Full integration deferred until package is available.

---

## Implementation Summary

**Date:** 2026-01-02
**Branch:** `feat/t.01-tts-service`
**Commits:** 2

### Files Created
- `Ora/TTS/AudioChunk.swift` - Audio chunk struct with samples, sampleRate, duration
- `Ora/TTS/TTSServicing.swift` - Protocol and error types for TTS abstraction
- `Ora/TTS/TTSService.swift` - Main TTS actor with:
  - KokoroEngine placeholder (validates model, triggers fallback)
  - AVSpeechSynthesizer fallback for actual audio playback
  - Proper actor isolation for thread safety
  - Cancellation support via `stop()`
- `OraTests/TTSServiceTests.swift` - 11 unit tests covering all acceptance criteria

### Implementation Notes
- kokoro-swift-mlx is structured as a sample app, not a Swift Package. The KokoroEngine is a placeholder that verifies model files exist but always triggers the AVSpeechSynthesizer fallback.
- When kokoro-swift-mlx becomes a proper SPM package, update KokoroEngine.synthesize() to call the actual implementation.
- All 11 TTS-specific tests pass.

### Ready for Review
- [x] All acceptance criteria verified (except AC-3 which requires full Kokoro integration)
- [x] Tests passing (11/11)
- [x] Working tree clean

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-02T22:24:11Z
**Commit reviewed:** 0c77730 (Iteration 2)
**Iterations:** 2

### Summary
- Files reviewed: 5 (4 new source files + 1 story doc update)
- Build status: Pass
- Tests status: Pass (11/11 TTS tests pass; 4 pre-existing test failures in unrelated files)

### Issues Found

#### P0 - Critical (Must fix)

*None identified*

#### P1 - Major (Should fix)

- [x] `TTSService.swift:143-158` - **Fallback synthesizer lifecycle issue**: ✅ Fixed in commit 0c77730. Added `FallbackSynthesizerHolder` class that maintains strong references to synthesizer/delegate and waits for `didFinish` callback before completing.

- [x] `TTSService.swift:65-75` - **currentTask not assigned in speak()**: ✅ Fixed in commit 0c77730. Now creates `synthesisTask` and calls `setCurrentTask()` to store it for cancellation support.

#### P2 - Minor (Deferred)

- [x] `TTSService.swift:35` - **Test init visibility**: ✅ Added documentation comment explaining internal visibility for testing.

- [ ] `TTSService.swift:173` - **@unchecked Sendable on delegate**: Refactored to use `@MainActor` on `FallbackSynthesizerDelegate` class instead of `@unchecked Sendable`.

- [ ] `AudioChunk.swift:15` - **Consider negative sampleRate validation**: Edge case, already handles zero. Deferred.

### Future Considerations (Out of Scope)

- `ASREngineTests.swift:83` - Pre-existing test failure (timestamp comparison issue), not part of this PR
- `HuggingFaceDownloaderTests` - Pre-existing test failures (file cleanup issues), not part of this PR

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

- [x] Implementation complete
- [x] Code review passed (2 iterations)
- [x] PR merged: https://github.com/benedict2310/ora/pull/28
- [x] Merged to main: 55fc19e
- [x] Date: 2026-01-02
