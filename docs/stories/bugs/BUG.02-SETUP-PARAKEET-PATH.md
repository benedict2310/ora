# BUG.02: Setup Wizard Polish + Parakeet Model Path Fix (Temp)

**Epic:** Foundations
**Status:** In Review
**Priority:** P1 (High)
**Severity:** Major
**Discovered:** 2026-01-06
**Reporter:** Onboarding test run

---

## 1. Summary

Two onboarding issues were addressed:
1. **Parakeet ASR verification failed** after download with: "Required model file missing: Encoder.mlmodelc".
2. **Setup wizard UI polish** (navigation consistency, liquid-glass layout) and **setup window focus** after permission grants.

---

## 2. Root Cause

1. **Parakeet model path mismatch:** FluidAudio caches ASR models under `~/Library/Application Support/FluidAudio/Models`, while Ora verified under `~/Library/Application Support/Ora/Models/...`. The download succeeded, but verification failed because the expected directory was empty.
2. **Setup UX fragmentation:** Action buttons and layout were inconsistent across steps, and permission grants allowed the setup window to drop behind other windows.

---

## 3. Fixes Applied

### 3.1 Parakeet Model Path
- `ModelPaths.path(for: .parakeetTDT)` now points to FluidAudio's cache root (`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml`).
- Updated model path tests to match the new location.

### 3.2 Setup Wizard Polish
- Added/extended a consistent bottom navigation bar across all setup steps.
- Reworked Welcome and Model Explanation layouts to fit the new navigation slot.
- Adjusted Download step action placement to use the shared navigation bar.
- Ensured the setup window returns to front after permission grants.

---

## 4. Files Changed

- `Ora/Models/ModelPaths.swift`
- `OraTests/ModelManagerTests.swift`
- `Ora/Setup/SetupCoordinator.swift`
- `Ora/Setup/SetupWindow.swift`
- `Ora/Setup/Steps/WelcomeStepView.swift`
- `Ora/Setup/Steps/PermissionsStepView.swift`
- `Ora/Setup/Steps/ModelExplanationStepView.swift`
- `Ora/Setup/Steps/DownloadStepView.swift`
- `Ora/Setup/Steps/ReadyStepView.swift`
- `OraTests/SetupViewsTests.swift`

---

## 5. Verification

### Automated
- `xcodebuild test -project Ora.xcodeproj -scheme Ora -only-testing:OraTests/ModelManagerTests`

### Manual
- Run setup wizard end-to-end and confirm:
  - Parakeet download completes without "Encoder.mlmodelc" error.
  - Bottom nav bar is present on Welcome, Model Explanation, and Download steps.
  - Setup window stays front-most after granting permissions.

---

## 6. Notes

This is a temporary story used to drive code review for the combined fixes and UI polish.

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-06T11:51:00Z
**Commit reviewed:** 8e20d7c
**Iteration:** 1

### Summary
- Files reviewed: 11
- Build status: Pass
- Tests status: Fail (1 failure)

### Issues Found

#### P0 - Critical (Must fix)
- [ ] `OraTests/ASREngineTests.swift:242` - `test_repoDirectory_containsParakeetPath` asserts that the path contains "Ora/Models/asr/parakeet". Since `ModelPaths.path(for: .parakeetTDT)` was updated to point to `FluidAudio/Models`, this test is failing. Update the test assertion to match the new path (e.g., check for "FluidAudio/Models").

#### P1 - Major (Should fix)
- None.

#### P2 - Minor (Can defer)
- None.

### Approval Status
- [ ] All P0 issues resolved
- [x] All P1 issues resolved
- [ ] Ready for merge

---

## Follow-up Fixes (2026-01-06)

- Updated `OraTests/ASREngineTests.swift` to assert the FluidAudio cache path (pending re-review).

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-06T11:55:00Z
**Commit reviewed:** 8e20d7c + unstaged fixes
**Iteration:** 2

### Summary
- Files reviewed: 12
- Build status: Pass
- Tests status: Pass (764 tests)

### Issues Found

#### P0 - Critical (Must fix)
- [x] `OraTests/ASREngineTests.swift:242` - Fixed assertion to match `FluidAudio/Models` path.

#### P1 - Major (Should fix)
- None.

#### P2 - Minor (Can defer)
- None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
