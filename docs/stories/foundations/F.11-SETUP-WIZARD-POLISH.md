# F.11 - Setup Wizard Polish

**Epic:** Foundations
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1-2 days
**Dependencies:** F.04, F.09
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Fix the broken-feeling model download screen in the setup wizard. While downloads work in the background, the UI doesn't properly communicate progress, completion, or errors - making users think it's stuck.

## 2. User Story

As a new user, I want clear feedback during model downloads so that I know the setup is working and how long to wait.

## 3. Scope

### In Scope

- Fix download progress display (show bytes/total, percentage, speed)
- Show download state clearly: Waiting → Downloading → Verifying → Ready
- Handle and display errors gracefully (network issues, disk space)
- Add cancel/retry capability for failed downloads
- Show estimated time remaining if possible
- Ensure "Continue" button only enables when all required models are ready
- Visual polish: loading spinners, checkmarks, error icons

### Out of Scope

- Changes to actual download mechanism (F.09)
- Model selection UI (covered by Preferences)
- Parallel downloads (current sequential is fine for now)
- Background download notifications

## 4. Architecture Alignment

- `SetupCoordinator` manages setup flow state
- `ModelManager` and `HuggingFaceDownloader` handle actual downloads
- Downloads publish progress via `@Published` properties or async streams
- Setup views observe progress and update UI reactively

### Current Issues (Based on User Feedback)

1. **Progress not visible**: Download is happening but UI doesn't show it
2. **No completion feedback**: Hard to tell when download finished
3. **Stuck appearance**: No spinners or activity indicators during download
4. **Error handling unclear**: Network failures don't show helpful messages

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None (polish existing components)

### 5.2 Files to Modify

- `Ora/Setup/Views/ModelDownloadStepView.swift` - Main download UI improvements
- `Ora/Setup/SetupCoordinator.swift` - Better state management for download progress
- `Ora/Models/ModelManager.swift` - Ensure progress events are published correctly
- `Ora/Models/Strategies/HuggingFaceDownloader.swift` - Improve progress reporting

### 5.3 Tests to Add

- `OraTests/Setup/SetupCoordinatorTests.swift` - Test download state transitions
- `OraTests/Models/ModelManagerTests.swift` - Test progress event publishing

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

### Progress Display
- [ ] AC-1: Download shows current file name being downloaded
- [ ] AC-2: Progress bar shows bytes downloaded / total bytes
- [ ] AC-3: Percentage and download speed (MB/s) displayed
- [ ] AC-4: Estimated time remaining shown (if calculable)

### State Feedback
- [ ] AC-5: Clear visual distinction between states: Pending → Downloading → Verifying → Ready → Error
- [ ] AC-6: Spinning indicator during active download
- [ ] AC-7: Checkmark when model is ready
- [ ] AC-8: Error icon with message when download fails

### Controls
- [ ] AC-9: Cancel button to abort current download
- [ ] AC-10: Retry button appears on error
- [ ] AC-11: "Continue" button disabled until all required models ready
- [ ] AC-12: "Continue" enables and shows success state when complete

### Error Handling
- [ ] AC-13: Network errors show user-friendly message
- [ ] AC-14: Disk space errors detected and reported
- [ ] AC-15: Partial downloads can be resumed or restarted

## 7. Verification Plan

### Automated Tests

- [ ] SetupCoordinator state machine tests
- [ ] Progress calculation tests

### Manual Tests

- [ ] Fresh install: Watch download progress from 0% to 100%
- [ ] Simulate slow network: See realistic progress updates
- [ ] Disable network mid-download: Error shown, retry works
- [ ] Complete download: See checkmark, Continue button enables
- [ ] Cancel download: Download stops, can restart

## 8. Performance / Reliability Considerations

- Progress updates should not spam UI (throttle to ~10 updates/second max)
- Large file downloads (4GB+) should show progress smoothly
- UI must remain responsive during downloads

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Progress events not firing | Verify HuggingFaceDownloader publishes correctly |
| UI updates too frequent causing lag | Throttle progress updates |
| Stuck state on network timeout | Add timeout handling with clear error |

## 10. Open Questions

- [ ] Should we show per-file progress for multi-file models?
- [ ] Should we estimate total time based on first file download speed?
- [ ] Add "Download in background" option for experienced users?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
