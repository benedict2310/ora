# M.08 - Remove Streaming ASR Models and Functionality

**Epic:** Maintenance
**Status:** Open
**Priority:** P2 (Medium)
**Estimated Effort:** 0.5-1 day
**Dependencies:** M.07 (Streaming ASR Migration - now superseded)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Remove all streaming ASR (Parakeet EOU) models and related functionality from the app. The batch mode with MacTalk-style "accumulate all, finalize once" approach (implemented in M.07 Issue 2 fix) provides accurate transcription for recordings up to 10 minutes, making streaming ASR unnecessary.

**Rationale:**
- Streaming ASR models require ~150MB additional download
- Batch mode now works correctly for long recordings (up to 10 min)
- Reduces complexity and maintenance burden
- Simplifies user experience (no model selection needed)

## 2. User Story

As a user, I want a simpler model download experience without optional ASR models that I don't need.

## 3. Scope

### In Scope

#### Code Removal
- [ ] Delete `Ora/ASR/StreamingParakeetEngine.swift`
- [ ] Delete `Ora/ASR/StreamingParakeetBootstrap.swift`
- [ ] Delete `Ora/ASR/StreamingASRConfiguration.swift`
- [ ] Delete `OraTests/StreamingParakeetEngineTests.swift`
- [ ] Remove streaming-related code from `ASRService.swift`:
  - `streamingEngine` property
  - `useStreamingMode` property
  - `runStreamingTranscription()` method
  - `StreamingStateTracker` actor
  - Streaming mode check in `prepare()`
  - Streaming-related imports

#### Model Infrastructure
- [ ] Remove `parakeetEOU160` and `parakeetEOU320` from `ModelTypes.swift`
- [ ] Remove streaming model download logic from `FluidAudioStrategy.swift`
- [ ] Remove streaming model paths from `ModelPaths.swift` (if applicable)
- [ ] Remove streaming models from Preferences UI model list

#### Settings
- [ ] Remove `useStreamingASR` from `AppSettings.swift`
- [ ] Remove `eouDebounceMs` from `AppSettings.swift`
- [ ] Remove streaming ASR toggle from Preferences UI (if present)

#### Documentation
- [ ] Update M.07 story to note streaming was removed in M.08
- [ ] Update CLAUDE.md if any streaming references exist
- [ ] Update PRD.md if streaming ASR is mentioned

### Out of Scope

- Changes to batch ASR functionality
- Changes to TTS or LLM pipelines
- FluidAudio package version changes

## 4. Files to Delete

| File | Purpose |
|------|---------|
| `Ora/ASR/StreamingParakeetEngine.swift` | Streaming ASR engine |
| `Ora/ASR/StreamingParakeetBootstrap.swift` | Streaming model bootstrap |
| `Ora/ASR/StreamingASRConfiguration.swift` | Streaming configuration |
| `OraTests/StreamingParakeetEngineTests.swift` | Streaming engine tests |

## 5. Files to Modify

| File | Change |
|------|--------|
| `Ora/ASR/ASRService.swift` | Remove streaming mode, simplify to batch-only |
| `Ora/Models/ModelTypes.swift` | Remove `parakeetEOU160`, `parakeetEOU320` |
| `Ora/Models/Strategies/FluidAudioStrategy.swift` | Remove `downloadStreamingModel()` |
| `Ora/Persistence/Models/AppSettings.swift` | Remove `useStreamingASR`, `eouDebounceMs` |
| `Ora/UI/Preferences/ModelsTab.swift` | Remove streaming models from list |

## 6. Acceptance Criteria

- [ ] AC-1: No streaming ASR code remains in codebase
- [ ] AC-2: No streaming models appear in Preferences > Models
- [ ] AC-3: AppSettings no longer has streaming-related properties
- [ ] AC-4: All tests pass after removal
- [ ] AC-5: Batch ASR continues to work correctly for recordings up to 10 minutes

## 7. Verification Plan

### Automated Tests
- [ ] All existing ASR tests pass
- [ ] No test failures due to missing streaming code

### Manual Tests
- [ ] App launches without errors
- [ ] ASR works for short recordings (<10s)
- [ ] ASR works for long recordings (30s-2min)
- [ ] Preferences > Models shows only batch ASR model
- [ ] No streaming-related settings visible in Preferences

## 8. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Accidental removal of batch ASR code | High | Low | Careful code review, test after each deletion |
| Breaking tests | Medium | Medium | Run tests frequently during removal |

## 9. Notes

This cleanup is a follow-up to M.07 where streaming ASR was implemented but ultimately not needed after the batch mode fix. The streaming infrastructure added complexity without benefit since:

1. Streaming models weren't downloaded by default
2. Batch mode with MacTalk-style approach handles long recordings correctly
3. Users reported no issues with batch mode after the fix

---

## Related Stories

- **M.07** - Streaming ASR Migration (implemented streaming, then fixed batch mode)
- **A.02** - ASR Service (original batch implementation)
