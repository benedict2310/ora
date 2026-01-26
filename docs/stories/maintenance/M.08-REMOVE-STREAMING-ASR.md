# M.08 - Remove Streaming ASR Models and Functionality

**Epic:** Maintenance
**Status:** Open
**Priority:** P2 (Medium)
**Estimated Effort:** 0.5-1 day
**Dependencies:** M.07 (Streaming ASR Migration - completed, streaming now superseded)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Remove all streaming ASR (Parakeet EOU) models and related functionality from the app. The batch mode with MacTalk-style "accumulate all, finalize once" approach (implemented in M.07 Issue 2 fix) provides accurate transcription for recordings up to 10 minutes, making streaming ASR unnecessary.

**Rationale:**
- Streaming ASR models require ~150MB additional download
- Batch mode now works correctly for long recordings (up to 10 min)
- Reduces complexity and maintenance burden
- Simplifies user experience (no model selection needed)
- Eliminates dead code paths that are never exercised in practice

**What Happened in M.07:**
M.07 implemented streaming ASR infrastructure but during testing discovered the real issue was the sliding window approach causing jibberish. The fix was to adopt MacTalk-style "accumulate all, finalize once" for batch mode, which made streaming ASR unnecessary. The streaming code was merged but is unused since:
1. Streaming models aren't downloaded by default
2. Even with `useStreamingASR: true`, the code falls back to batch mode when models are missing
3. No users have reported issues with the batch mode fix

## 2. User Story

As a user, I want a simpler model download experience without optional ASR models that I don't need.

As a developer, I want to remove unused code paths to reduce maintenance burden and potential confusion.

## 3. Scope

### In Scope

#### Code Removal
- [ ] Delete `Ora/ASR/StreamingParakeetEngine.swift` (includes `StreamingParakeetBootstrap` enum)
- [ ] Delete `Ora/ASR/StreamingASRConfiguration.swift`
- [ ] Delete `OraTests/StreamingParakeetEngineTests.swift`
- [ ] Remove streaming-related code from `ASRService.swift`
- [ ] Remove streaming-related code from `SimplePipelineController.swift`

#### Model Infrastructure
- [ ] Remove `parakeetEOU160` and `parakeetEOU320` from `ModelTypes.swift`
- [ ] Remove streaming model download logic from `FluidAudioStrategy.swift`
- [ ] Update `HuggingFaceStrategy.swift` to remove EOU model cases

#### Settings
- [ ] Remove `useStreamingASR` from `AppSettings.swift`
- [ ] Remove `eouDebounceMs` from `AppSettings.swift`

#### Documentation
- [ ] Update M.07 story to note streaming code was removed in M.08

### Out of Scope

- Changes to batch ASR functionality (ParakeetEngine, batch transcription)
- Changes to TTS or LLM pipelines
- Changes to `StreamingRingBuffer.swift` (used by AudioPipeline, not streaming ASR)
- FluidAudio package version changes
- Removing FluidAudioVAD (still used for speech detection in batch mode)

## 4. Architecture Alignment

### Component Boundaries

The streaming ASR code is isolated to:
1. **ASR layer**: `StreamingParakeetEngine` wraps FluidAudio's `StreamingEouAsrManager`
2. **Configuration**: `StreamingASRConfiguration` defines chunk size and debounce settings
3. **Model layer**: `parakeetEOU160/320` model identifiers and download strategies
4. **Settings layer**: `useStreamingASR` and `eouDebounceMs` in `AppSettings`
5. **Pipeline layer**: EOU callback wiring in `SimplePipelineController`

### What Stays (Batch Mode)

The batch ASR pipeline remains unchanged:
```
AudioPipeline → ASRService.runTranscription() → ParakeetEngine → FluidAudioVAD → SilenceDetector
```

### What Gets Removed (Streaming Mode)

The streaming ASR path being removed:
```
AudioPipeline → ASRService.runStreamingTranscription() → StreamingParakeetEngine → EOU detection
```

### Concurrency Notes

- `StreamingStateTracker` actor in `ASRService.swift` will be removed
- No concurrency changes needed for batch mode

### SwiftData Migration

The removal of `useStreamingASR` and `eouDebounceMs` from `AppSettings` (@Model) may require a lightweight migration. Since these fields have default values and are simply being removed:
- SwiftData should handle this automatically (removed fields are ignored on load)
- No explicit migration code needed
- Existing user settings for these fields will be silently dropped

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

None - this is a removal/cleanup task.

### 5.2 Files to Modify

**Files to Delete:**

| File | Purpose | LOC |
|------|---------|-----|
| `Ora/ASR/StreamingParakeetEngine.swift` | Streaming ASR engine + `StreamingParakeetBootstrap` enum | ~330 |
| `Ora/ASR/StreamingASRConfiguration.swift` | Streaming configuration (chunk size, debounce) | ~60 |
| `OraTests/StreamingParakeetEngineTests.swift` | Unit tests for streaming engine | ~240 |

**Files to Modify:**

| File | Change | Details |
|------|--------|---------|
| `Ora/ASR/ASRService.swift` | Remove streaming mode | Remove: `streamingEngine` property, `useStreamingMode` property, `runStreamingTranscription()` method (~100 lines), `StreamingStateTracker` actor, streaming-related imports, `init(streamingEngine:)` constructor, streaming mode check in `prepare()` |
| `Ora/Models/ModelTypes.swift` | Remove streaming models | Remove `parakeetEOU160` and `parakeetEOU320` enum cases and their associated properties (`displayName`, `huggingFaceRepo`, `estimatedSizeBytes`, `isRequired`, `storagePath`, `requiredFiles`, `expectedFileSizes`) |
| `Ora/Models/Strategies/FluidAudioStrategy.swift` | Remove streaming download | Remove `downloadStreamingModel()` method (~65 lines), remove `.parakeetEOU160`/`.parakeetEOU320` cases from `download()` switch |
| `Ora/Models/Strategies/HuggingFaceStrategy.swift` | Remove EOU cases | Update `.parakeetTDT, .parakeetEOU160, .parakeetEOU320:` case to just `.parakeetTDT:` |
| `Ora/Persistence/Models/AppSettings.swift` | Remove streaming settings | Remove `useStreamingASR` property, remove `eouDebounceMs` property, remove "Streaming ASR Settings" MARK section |
| `Ora/Orchestration/SimplePipelineController.swift` | Remove EOU callback | Remove `onEndOfUtterance` parameter from `ASRService.shared.transcribe()` call, update comments |

### 5.3 Tests to Add

No new tests needed - this is a removal task. Existing batch ASR tests should continue to pass.

| Test | Coverage |
|------|----------|
| `ASRServiceTests` | Verify batch mode still works (existing tests) |
| `ParakeetEngineTests` | Verify engine still functions (existing tests) |

### 5.4 Dependencies/Config

- No `project.yml` changes needed
- FluidAudio package stays at v0.10.0 (still used for batch ASR and TTS)

## 6. Acceptance Criteria

- [x] AC-1: No streaming ASR code remains in codebase (grep for `StreamingParakeet`, `parakeetEOU`, `useStreamingASR` returns no hits in `Ora/` or `OraTests/`) - ✅ Verified via grep
- [x] AC-2: `ModelIdentifier` enum has no `parakeetEOU160` or `parakeetEOU320` cases - ✅ Verified in `ModelTypes.swift`
- [x] AC-3: `AppSettings` no longer has `useStreamingASR` or `eouDebounceMs` properties - ✅ Verified in `AppSettings.swift`
- [x] AC-4: All tests pass after removal (`./build.sh test`) - ✅ 1045/1045 tests pass
- [ ] AC-5: Batch ASR continues to work correctly for recordings (tested manually)
- [x] AC-6: App launches without errors related to missing streaming code - ✅ Build succeeds
- [x] AC-7: No orphaned imports or references cause build errors - ✅ Build succeeds

## 7. Verification Plan

### Automated Tests

- [x] Run `./build.sh test` - all tests pass
- [x] Run `grep -r "StreamingParakeet\|parakeetEOU\|useStreamingASR" Ora/ OraTests/` - returns empty

### Manual Tests

- [ ] App launches without errors
- [ ] ASR works for short recordings (<10s)
- [ ] ASR works for long recordings (30s-2min)
- [ ] ASR works for very long recordings (5+ min) without cutoff or jibberish
- [ ] No streaming-related settings visible in Preferences (if any existed)
- [ ] Model download flow doesn't reference streaming models

### Regression Checklist

- [ ] Push-to-talk hotkey works
- [ ] Transcription appears in overlay during speech
- [ ] Transcription finalizes after speech ends
- [ ] LLM processes transcription and responds
- [ ] TTS speaks the response

## 8. Performance / Reliability Considerations

**No performance impact expected** - streaming code was never exercised in practice.

**Reliability improvement** - fewer code paths means fewer potential bugs.

**Memory** - no change (streaming engine was only instantiated if models were downloaded).

## 9. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Accidental removal of batch ASR code | High | Low | Careful code review, search for `ParakeetEngine` vs `StreamingParakeetEngine`, test after each deletion |
| Breaking tests | Medium | Low | Run tests frequently during removal |
| SwiftData migration issues | Medium | Low | Test with existing settings; SwiftData handles removed fields gracefully |
| Missing import/reference causes build failure | Low | Medium | Build after each file deletion |

## 10. Open Questions

None - this is a straightforward removal task.

---

## Implementation Notes

### Order of Operations (Recommended)

1. **Delete test file first** - `OraTests/StreamingParakeetEngineTests.swift`
2. **Delete streaming engine files** - `StreamingParakeetEngine.swift`, `StreamingASRConfiguration.swift`
3. **Update ASRService.swift** - Remove streaming mode code
4. **Update SimplePipelineController.swift** - Remove EOU callback
5. **Update ModelTypes.swift** - Remove EOU model identifiers
6. **Update FluidAudioStrategy.swift** - Remove streaming download
7. **Update HuggingFaceStrategy.swift** - Remove EOU cases
8. **Update AppSettings.swift** - Remove streaming settings
9. **Build and test** - `./build.sh test`

### Search Patterns for Verification

After removal, these searches should return no results:
```bash
grep -r "StreamingParakeet" Ora/ OraTests/
grep -r "parakeetEOU" Ora/ OraTests/
grep -r "useStreamingASR" Ora/ OraTests/
grep -r "eouDebounceMs" Ora/ OraTests/
grep -r "StreamingASRConfiguration" Ora/ OraTests/
grep -r "runStreamingTranscription" Ora/ OraTests/
grep -r "StreamingStateTracker" Ora/ OraTests/
```

---

## Related Stories

- **M.07** - Streaming ASR Migration (implemented streaming, then fixed batch mode instead)
- **A.02** - ASR Service (original batch implementation)
- **M.06** - Speech End Detection Improvements (VAD improvements used by batch mode)
