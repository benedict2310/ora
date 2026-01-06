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

- [ ] AC-1: Default silence timeout is 1.0s (reduced from 1.5s)
- [ ] AC-2: Silence timeout is configurable in Preferences (0.5s - 2.0s range)
- [ ] AC-3: User preference persists across app restarts

### VAD-Assisted Detection

- [ ] AC-4: VAD speechEnd triggers 300ms confirmation timer
- [ ] AC-5: VAD speechStart cancels pending confirmation
- [ ] AC-6: Confirmation timer respects minimum transcript length (no empty submits)
- [ ] AC-7: ASR partial during confirmation resets the timer
- [ ] AC-8: System falls back to ASR-only if VAD events unavailable

### User Experience

- [ ] AC-9: Short phrases ("yes", "no", "thanks") are captured correctly
- [ ] AC-10: Long pauses mid-sentence don't trigger premature submission
- [ ] AC-11: Effective end-to-end delay is <1.0s for typical utterances
- [ ] AC-12: Multi-turn conversation feels responsive and natural

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for VAD-assisted confirmation timer
- [ ] Unit tests for speechStart cancellation
- [ ] Unit tests for fallback to ASR-only mode
- [ ] Unit tests for user preference integration

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

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
