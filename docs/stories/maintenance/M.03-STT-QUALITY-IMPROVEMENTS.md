# M.03 - Response Triggering Improvements

**Epic:** Maintenance
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1-2 days
**Dependencies:** O.07
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Improve conversation responsiveness by reducing the time between when the user stops speaking and when Ora processes their request. Currently this delay is ~1.9s; target is <1.0s.

## 2. User Story

As a user, I want Ora to respond faster after I stop speaking so that conversations feel natural and snappy, not sluggish.

## 3. Scope

### In Scope

- Reduce default silence timeout from 1.5s to 1.0s
- Add silence timeout preference (0.5s - 2.0s slider)
- Implement VAD-assisted end-of-speech detection
- Add VAD confirmation timer (300ms)
- Wire VAD transition events to SilenceDetector

### Out of Scope

- Noise suppression / audio preprocessing (see M.04)
- Changes to VAD thresholds or algorithm
- Changes to Parakeet ASR engine
- Visual "confirming silence" state indicator

## 4. Architecture Alignment

### Component Boundaries

- **SilenceDetector** (Orchestration layer): Adds VAD-assisted mode alongside existing ASR-based detection
- **SimplePipelineController** (Orchestration layer): Wires VAD events to SilenceDetector
- **StreamingManager** (ASR layer): Already emits VAD state via `onVADStateChange(Bool)` callback
- No changes to ASR/Audio layers required

### Concurrency Model

- SilenceDetector is `@MainActor` - all callbacks already on main thread
- VAD transitions from StreamingManager are posted to MainActor
- Confirmation timer uses Swift Concurrency (`Task.sleep`)

### Pipeline Boundaries

- Preserves ASR → LLM → Tools → TTS boundary
- SilenceDetector remains an orchestration concern
- No changes to audio thread or real-time constraints

### Current State Analysis

**Current implementation:** `Ora/Orchestration/SilenceDetector.swift`

```
User stops speaking
    ↓ (~400ms wait for next ASR hop)
No new ASR partial detected
    ↓ (1.5s timeout starts)
Timeout fires → auto-submit
```

**Total effective delay: ~1.9 seconds**

| Component | Delay | Reason |
|-----------|-------|--------|
| ASR hop interval | ~400ms | Parakeet processes every 400ms |
| Silence timeout | 1500ms | Waits after last partial |
| **Total** | **~1900ms** | Too long for natural conversation |

### Proposed Flow

```
User stops speaking
    ↓ (~30ms VAD detects speechEnd)
VAD confirmation timer starts (300ms)
    ↓ (no new speech detected)
Confirmation fires → auto-submit
```

**New effective delay: ~330ms** (6x improvement)

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

None required - extending existing components.

### 5.2 Files to Modify

| File | Changes |
|------|---------|
| `Ora/Orchestration/SilenceDetector.swift` | Add VAD-assisted mode, confirmation timer, reduce default timeout |
| `Ora/Orchestration/SimplePipelineController.swift` | Wire VAD speechEnd/speechStart to SilenceDetector |
| `Ora/Persistence/Models/AppSettings.swift` | Add `silenceTimeout` preference |
| `Ora/Preferences/Tabs/GeneralPreferencesView.swift` | Add silence timeout slider |

### 5.3 Tests to Add

| Test File | Coverage |
|-----------|----------|
| `OraTests/Orchestration/SilenceDetectorTests.swift` | VAD-assisted mode, confirmation timer, timeout variations |

**New test cases:**
- `test_vadAssistedDetection_triggersOnSpeechEnd` - VAD speechEnd starts confirmation
- `test_vadConfirmation_cancelledOnSpeechResume` - speechStart cancels pending confirmation
- `test_vadConfirmation_triggersAfterDelay` - 300ms confirmation fires correctly
- `test_fallbackToASROnly_whenVADDisabled` - ASR-only mode still works
- `test_silenceTimeout_respectsUserPreference` - Custom timeout is honored

### 5.4 Dependencies/Config

No external dependencies or project.yml changes required.

### 5.5 Key Implementation Details

**SilenceDetector Changes:**

```swift
@MainActor
final class SilenceDetector {
    // MARK: - Constants
    static let defaultTimeout: TimeInterval = 1.0  // Reduced from 1.5s
    static let vadConfirmationDelay: TimeInterval = 0.3

    // MARK: - VAD Integration
    private var confirmationTask: Task<Void, Never>?

    func onVADStateChanged(isSpeech: Bool) {
        if !isSpeech && hasReceivedPartial {
            startConfirmationTimer()
        } else if isSpeech {
            cancelConfirmationTimer()
        }
    }
}
```

**SimplePipelineController Wiring:**

```swift
private func wireVADToSilenceDetector() {
    streamingManager.onVADStateChange = { [weak self] isSpeech in
        self?.silenceDetector?.onVADStateChanged(isSpeech: isSpeech)
    }
}
```

## 6. Acceptance Criteria

### Timeout Reduction

- [x] AC-1: Default silence timeout is 1.0s (reduced from 1.5s) - ✅ Verified in `SilenceDetector.swift:17`
- [x] AC-2: Silence timeout is configurable in Preferences (0.5s - 2.0s range) - ✅ Verified in `GeneralPreferencesView.swift:73-93`
- [x] AC-3: User preference persists across app restarts - ✅ Verified in `AppSettings.swift:34-35`

### VAD-Assisted Detection

- [x] AC-4: VAD speechEnd triggers 300ms confirmation timer - ✅ Verified by `test_vadAssistedDetection_triggersOnSpeechEnd`
- [x] AC-5: VAD speechStart cancels pending confirmation - ✅ Verified by `test_vadConfirmation_cancelledOnSpeechResume`
- [x] AC-6: Confirmation timer respects minimum transcript length (no empty submits) - ✅ Verified by `test_vadSpeechEndWithoutPartial_doesNotTrigger`
- [x] AC-7: ASR partial during confirmation resets the timer - ✅ Verified by `test_partialDuringVADConfirmation_resetsTimer`
- [x] AC-8: System falls back to ASR-only if VAD events unavailable - ✅ Verified by `test_fallbackToASROnly_whenNoVADEvents`

### User Experience

- [ ] AC-9: Short phrases ("yes", "no", "thanks") are captured correctly - 🧪 Requires manual testing
- [ ] AC-10: Long pauses mid-sentence don't trigger premature submission - 🧪 Requires manual testing
- [ ] AC-11: Effective end-to-end delay is <1.0s for typical utterances - 🧪 Requires manual testing
- [ ] AC-12: Multi-turn conversation feels responsive and natural - 🧪 Requires manual testing

## 7. Verification Plan

### Automated Tests

- [x] Unit tests for VAD-assisted confirmation timer - ✅ 31 tests in SilenceDetectorTests
- [x] Unit tests for speechStart cancellation - ✅ `test_vadConfirmation_cancelledOnSpeechResume`
- [x] Unit tests for fallback to ASR-only mode - ✅ `test_fallbackToASROnly_whenNoVADEvents`
- [x] Unit tests for user preference integration - ✅ `test_init_withCustomTimeout`, `test_init_clampsTimeoutToMinimum`, `test_init_clampsTimeoutToMaximum`

### Manual Tests

- [ ] Press hotkey, say "yes", verify quick submission (~300-500ms)
- [ ] Press hotkey, say long sentence with pauses, verify no premature submit
- [ ] Multi-turn conversation flows smoothly without perceptible delay
- [ ] Change timeout in Preferences, verify new value takes effect
- [ ] Disable conversation mode, verify manual submit still works

## 8. Performance / Reliability Considerations

| Metric | Current | Target |
|--------|---------|--------|
| End-of-speech to submission | ~1.9s | <1.0s |
| VAD response time | ~30ms | <50ms |
| Confirmation delay | N/A | 300ms |

**Reliability:**
- VAD-assisted mode is additive; ASR-only fallback ensures no regression
- Confirmation timer prevents premature triggers on VAD noise
- User preference allows tuning for individual speech patterns

## 9. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Premature triggers with short timeout | Medium | Medium | VAD confirmation prevents most false triggers |
| VAD misses speech end in noise | Low | Low | Falls back to ASR timeout |
| User dislikes faster triggering | Low | Low | Configurable timeout in Preferences |

## 10. Open Questions

- [x] What's the ideal VAD confirmation delay? **Decision: 300ms**
- [x] Should VAD-assisted mode be toggleable? **Decision: No, always on with fallback**
- [ ] Do we need a visual indicator during confirmation? **Propose: No, keep it seamless**

---

## Implementation Summary

**Date:** 2026-01-06
**Branch:** `feat/M.03-response-triggering`
**Commits:** 1

### Files Changed

| File | Change |
|------|--------|
| `Ora/ASR/ASRService.swift` | Added VAD state change callback to transcription API |
| `Ora/Orchestration/SilenceDetector.swift` | Complete rewrite with VAD-assisted detection, confirmation timer, timeout clamping |
| `Ora/Orchestration/SimplePipelineController.swift` | Wire VAD events to SilenceDetector, use user preference for timeout |
| `Ora/Persistence/Models/AppSettings.swift` | Add `silenceTimeout` preference (default 1.0s) |
| `Ora/Preferences/Tabs/GeneralPreferencesView.swift` | Add silence timeout slider (0.5s-2.0s) under Conversation Mode |
| `OraTests/Orchestration/SilenceDetectorTests.swift` | Expanded from 15 to 31 tests covering VAD-assisted mode |

### Key Design Decisions

1. **VAD events via ASRService**: Rather than using StreamingManager directly (which isn't used by SimplePipelineController), added VAD state callbacks to ASRService's transcription method
2. **Dual-mode detection**: VAD-assisted mode (primary) with ASR timeout fallback ensures reliability
3. **Confirmation timer**: 300ms delay after VAD speechEnd prevents false triggers
4. **Timeout clamping**: User preferences clamped to 0.5s-2.0s range to prevent unusable values

### Expected Performance Improvement

| Metric | Before | After |
|--------|--------|-------|
| ASR hop wait | ~400ms | ~30ms (VAD) |
| Silence timeout | 1500ms | 300ms (VAD confirmation) |
| **Total delay** | **~1900ms** | **~330ms** |

### Ready for Review

- [x] All acceptance criteria verified (8/8 automated, 4 require manual testing)
- [x] Tests passing (780 tests, 0 failures)
- [x] Working tree clean

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
