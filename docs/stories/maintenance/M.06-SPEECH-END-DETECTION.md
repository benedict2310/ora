# M.06 - Speech End Detection Improvements

**Epic:** Maintenance
**Status:** Draft
**Priority:** P1 (High)
**Estimated Effort:** 3-5 days
**Dependencies:** M.03
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Fix inconsistent speech end detection that causes two failure modes:
1. **Ends too quickly** - Transcription submits before user finishes speaking
2. **Doesn't stop / jitters** - Transcription continues indefinitely with deteriorating quality

## 2. User Story

As a user, I want Ora to reliably detect when I've finished speaking so that my complete utterances are captured without premature cutoffs or endless jittering.

## 3. Problem Analysis

### 3.1 Current Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  AudioPipeline  │───▶│   ASRService    │───▶│ SilenceDetector │
│  (300ms chunks) │    │ (full buffer    │    │ (VAD + timeout) │
│                 │    │  reprocessing)  │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                     │                      │
         │              EnergyVAD (RMS)         VAD confirmation
         │              runs per-frame          timer (300ms)
         └─────────────────────────────────────────────┘
```

### 3.2 Root Causes Identified

#### Issue 1: ASRService Full-Buffer Reprocessing (Causes Jitter)

**Location:** `Ora/ASR/ASRService.swift:210-232`

ASRService accumulates ALL audio (up to 10 seconds) and re-transcribes the **entire buffer** on every 300ms chunk:

```swift
// Current behavior - processes entire accumulated buffer
if accumulatedSamples.count >= minimumSamples {
    let paddedSamples = ensureMinimumDuration(accumulatedSamples)
    let partial = try await engine.process(samples: paddedSamples, ...)
}
```

**Problem:** As the buffer grows (1s → 5s → 10s), Parakeet produces slightly different transcriptions for the same audio, causing visible jitter and triggering false "partial received" events that reset silence detection timers.

**Contrast with StreamingManager:** `Ora/ASR/StreamingManager.swift` uses hop-based processing with a rolling window (`peekLatest`) and `PartialDiffer` for text stability, but **is not currently used** by `SimplePipelineController`.

#### Issue 2: EnergyVAD vs FluidAudio's Silero VAD

**Location:** `Ora/ASR/VoiceActivityDetector.swift`

Ora uses a custom RMS energy-based VAD with fixed thresholds:
- `speechThreshold: 0.01`
- `silenceThreshold: 0.005`
- `hangoverFrames: 8` (240ms)

**Problems:**
- RMS energy is not robust to background noise variations
- Fixed thresholds don't adapt to environment/mic gain
- No neural network-based speech probability

**FluidAudio provides:** Silero-based neural VAD with:
- `VadConfig(threshold: 0.7)` - neural network probability threshold
- `minSpeechDuration` - avoids false starts
- `minSilenceGap` - avoids premature ends
- Speech probability output for smarter decisions

#### Issue 3: ASR Partials Cancel VAD Confirmation

**Location:** `Ora/Orchestration/SilenceDetector.swift:114-116`

```swift
// Cancel VAD confirmation if pending (AC-7: partial during confirmation resets)
self.vadConfirmationTask?.cancel()
self.vadConfirmationTask = nil
```

**Problem:** Even after VAD detects `speechEnd`, any ASR partial (including minor text corrections from full-buffer reprocessing) cancels the 300ms confirmation timer. With ASRService constantly producing variations, silence detection rarely triggers via the VAD path.

#### Issue 4: No Transcript Stabilization

**Problem:** ASRService emits partials for every transcription, even when text hasn't meaningfully changed. The punctuation filter in `SilenceDetector.normalizeForComparison()` is a workaround but doesn't catch all variations (capitalization, minor word changes).

**Solution exists but unused:** `StreamingManager` uses `PartialDiffer` which computes longest common prefix across partials and only emits when stable text changes.

### 3.3 Symptom Mapping

| Symptom | Root Cause |
|---------|------------|
| Ends too fast | EnergyVAD `silenceThreshold` too low (0.005); short hangover (240ms); brief pauses trigger speechEnd |
| Jitter/deterioration | Full-buffer reprocessing produces varying results; partials reset timers |
| Doesn't stop | Background noise above threshold keeps VAD in speech state; partials keep canceling VAD confirmation |

## 4. Proposed Solutions

### Option A: Migrate to FluidAudio VAD (Recommended)

Replace EnergyVAD with FluidAudio's Silero-based VAD:

**Pros:**
- Neural network-based, more robust to noise
- Already bundled with FluidAudio SDK
- Provides probability scores for confidence-based decisions
- Includes `minSpeechDuration` and `minSilenceGap` parameters

**Cons:**
- Requires FluidAudio VAD model loading
- May increase memory footprint slightly

### Option B: Use StreamingManager Instead of ASRService

Replace ASRService with StreamingManager which was designed for this use case:

**Pros:**
- Hop-based processing (400ms intervals) instead of full-buffer reprocessing
- Built-in `PartialDiffer` for text stability
- VAD gating that skips transcription during silence
- Already implemented and tested

**Cons:**
- May require refactoring SimplePipelineController integration
- Different API patterns

### Option C: Hybrid - Fix ASRService + Use FluidAudio VAD

1. Add text stability detection to ASRService (don't emit partials unless text meaningfully changed)
2. Replace EnergyVAD with FluidAudio's Silero VAD
3. Decouple partial emissions from VAD confirmation (don't let ASR partials reset VAD timer after speechEnd detected)

### Option D: Use FluidAudio EOU Model

FluidAudio provides a dedicated End-of-Utterance model: `parakeet-realtime-eou-120m-coreml`

**Pros:**
- Purpose-built for end-of-speech detection
- Reduces reliance on hand-tuned thresholds

**Cons:**
- Additional model to load
- May increase latency/memory

## 5. Recommended Approach

**Phase 1: Quick Wins (1-2 days)**
1. Add text stability check to ASRService - only emit partial if text meaningfully changed
2. Decouple VAD confirmation from ASR partials - once VAD detects speechEnd, don't let partials cancel it
3. Tune EnergyVAD thresholds based on environment testing

**Phase 2: Proper Fix (2-3 days)**
1. Integrate FluidAudio's Silero VAD to replace EnergyVAD
2. Add configurable `minSpeechDuration` and `minSilenceGap` parameters
3. Add "finalize fallbacks":
   - No-change timeout: if ASR text unchanged for 500-800ms → finalize
   - Hard max duration: after 10s → force finalize

**Phase 3: Optional Enhancement**
- Evaluate FluidAudio EOU model for always-on scenarios
- Add adaptive threshold based on ambient noise level

## 6. Implementation Plan

### 6.1 Files to Modify

| File | Changes |
|------|---------|
| `Ora/ASR/ASRService.swift` | Add text stability detection; only emit partial when text meaningfully changed |
| `Ora/Orchestration/SilenceDetector.swift` | Decouple VAD confirmation from ASR partials; add no-change timeout |
| `Ora/ASR/VoiceActivityDetector.swift` | Replace EnergyVAD with FluidAudio Silero VAD wrapper |
| `Ora/Persistence/Models/AppSettings.swift` | Add `minSpeechDuration`, `minSilenceGap` preferences |
| `Ora/Preferences/Tabs/GeneralPreferencesView.swift` | Add VAD tuning controls (optional) |

### 6.2 Files to Create

| File | Purpose |
|------|---------|
| `Ora/ASR/FluidAudioVAD.swift` | Wrapper for FluidAudio's Silero VAD |
| `Ora/ASR/TranscriptStabilizer.swift` | Text stability detection (longest common prefix, etc.) |

### 6.3 Tests to Add

| Test | Coverage |
|------|----------|
| `test_textStability_ignoresMinorChanges` | ASRService doesn't emit partial for punctuation/capitalization only |
| `test_vadConfirmation_notCancelledByPartialAfterSpeechEnd` | Once VAD speechEnd, partials don't reset timer |
| `test_noChangeTimeout_finalizesAfterStableText` | Finalize after 500-800ms of unchanged text |
| `test_fluidAudioVAD_detectsSpeechEnd` | FluidAudio VAD integration works |

## 7. Acceptance Criteria

### Text Stability
- [ ] AC-1: ASRService only emits partial when text meaningfully changed (not punctuation/capitalization only)
- [ ] AC-2: Consecutive identical partials don't trigger multiple events

### VAD Improvements
- [ ] AC-3: VAD speechEnd confirmation not cancelled by ASR partials
- [ ] AC-4: FluidAudio Silero VAD used instead of EnergyVAD
- [ ] AC-5: `minSpeechDuration` prevents false starts (default 0.25s)
- [ ] AC-6: `minSilenceGap` prevents premature ends (default 0.5s)

### Finalize Fallbacks
- [ ] AC-7: No-change timeout finalizes after 500-800ms of stable text
- [ ] AC-8: Hard max duration forces finalize after 10s

### User Experience
- [ ] AC-9: Short phrases ("yes", "no") captured correctly without premature cutoff
- [ ] AC-10: Long sentences with natural pauses don't trigger early submission
- [ ] AC-11: Transcription doesn't jitter or deteriorate during extended speech
- [ ] AC-12: Works reliably in quiet and moderately noisy environments

## 8. Verification Plan

### Automated Tests
- Unit tests for text stability detection
- Unit tests for VAD confirmation behavior
- Unit tests for finalize fallbacks

### Manual Tests
- [ ] Say "yes" quickly → captured without cutoff
- [ ] Say long sentence with pauses → no premature submit
- [ ] Speak for 8+ seconds → transcription remains stable (no jitter)
- [ ] Test in quiet room → works correctly
- [ ] Test with background noise (fan, music) → works correctly
- [ ] Multi-turn conversation → responsive and reliable

## 9. Performance Considerations

| Metric | Current | Target |
|--------|---------|--------|
| Speech end detection latency | ~330ms (VAD) or ~1s (ASR fallback) | <500ms consistent |
| False positive rate (early cutoff) | Unknown (too high) | <5% |
| False negative rate (no cutoff) | Unknown (too high) | <5% |
| Transcription stability | Jittery with long audio | Stable throughout |

## 10. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| FluidAudio VAD increases memory | Low | Medium | Lazy load VAD model; unload when idle |
| Tuned thresholds don't generalize | Medium | Medium | Add user-adjustable sensitivity; environment presets |
| Text stability too aggressive | Medium | Low | Tune stability threshold; test edge cases |
| Breaking change to ASR pipeline | High | Low | Incremental changes; feature flag for rollback |

## 11. Research References

### FluidAudio VAD Capabilities
- `VadConfig(threshold: 0.7)` - neural probability threshold (Silero-based)
- `minSpeechDuration` - recommended 0.25s for assistant commands
- `minSilenceGap` - recommended 0.4-0.6s for natural speech
- CLI tools: `vad-analyze --streaming` for environment tuning

### Recommended VAD Tuning (Assistant Commands)
From user research:
- `defaultThreshold`: 0.65-0.80
- `minSpeechDuration`: 0.20-0.35s
- `minSilenceGap`: 0.45-0.80s
- Max utterance duration: 8-12s safety cutoff

### Transcript Stabilization Pattern
```swift
// Commit stable prefix across last N partials
var committedText: String
var liveText: String

// Compute longest common prefix across last 2-3 partials
// Move stable prefix to committedText
// Only allow last 3-6 words to remain "editable"
```

## 12. Open Questions

- [ ] Should we expose VAD sensitivity to users, or auto-detect based on ambient noise?
- [ ] Is the 10s max utterance duration appropriate for all use cases?
- [ ] Should we log VAD probabilities for debugging in verbose mode?
- [ ] Does FluidAudio's EOU model provide enough benefit to justify the additional model load?

---

## Related Issues

- **M.03** - Response Triggering Improvements (implemented VAD-assisted detection, but issues remain)
- **O.07** - Conversation Mode (introduced silence detection)
