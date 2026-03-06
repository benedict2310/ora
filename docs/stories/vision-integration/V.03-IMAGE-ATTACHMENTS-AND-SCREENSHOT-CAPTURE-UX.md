# V.03 - Image Attachments & Screenshot Capture UX

**Epic:** Vision Integration
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 3-4 days
**Dependencies:** V.01, F.06, F.07
**Target:** macOS 26 (Tahoe)
**Design Reference:** [PRD.md - Future Phases](../PRD.md#future-phases)

---

## 1. Objective

Let users attach an image to the next Ora turn through a clear overlay workflow so vision support feels intentional, private, and native instead of hidden behind debug-only plumbing.

## 2. User Story

As a user, I want to paste an image, choose a file, or capture a screenshot before speaking so that I can ask Ora about what I am looking at without leaving my workflow.

## 3. Scope

### In Scope

- Add attachment actions to the overlay for:
  - paste image from clipboard
  - choose image file
  - capture screenshot
- Stage selected images into an app-managed attachment store under Application Support.
- Show pending attachment chips or previews in the overlay before the turn is submitted.
- Allow removing one attachment or clearing all pending attachments before submission.
- Use ScreenCaptureKit screenshot APIs for capture, with proper permission guidance.
- Fall back gracefully when screenshot permission is denied by keeping pasteboard/file-import actions available.

### Out of Scope

- PDF/document ingestion
- Live screen sharing or continuous capture
- Video attachments
- OCR-specific features beyond whatever the VLM can infer directly

## 4. Architecture Alignment

- Keep the overlay as the user-facing attachment surface; do not add a second standalone capture window unless the screenshot API requires it temporarily.
- Use an actor-backed attachment store for staging and cleanup rather than embedding raw `NSImage` data in view state or SwiftData.
- Keep screenshot permission optional and on-demand; it must not become part of required first-run setup.
- Align with existing permissions guidance patterns but do not overload the core required-permissions flow.
- Relevant macOS APIs:
  - `NSPasteboard` for pasted images
  - `NSOpenPanel` for image file selection
  - ScreenCaptureKit for screenshots

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/LLM/AttachmentStore.swift` - Actor that stages images, returns attachment references, and handles cleanup.
- `Ora/Overlay/AttachmentTrayView.swift` - Pending attachment chips/previews and remove actions.
- `Ora/Utilities/ScreenshotCaptureService.swift` - ScreenCaptureKit-based screenshot helper with permission-aware error mapping.

### 5.2 Files to Modify

- `Ora/Overlay/OverlayState.swift` - Track pending image attachments in overlay state.
- `Ora/Overlay/OverlayView.swift` - Render attachment tray above the conversation list or input control.
- `Ora/Overlay/VoiceInputControlView.swift` - Add affordances for image attachment actions without breaking current voice-first behavior.
- `Ora/Orchestration/SimplePipelineController.swift` - Hold pending attachments for the next turn and clear them at the right lifecycle boundaries.
- `Ora/Preferences/Tabs/PermissionsPreferencesView.swift` - Surface screenshot permission guidance if the app exposes optional permissions there.
- `Ora/Permissions/PermissionTypes.swift` - Add an optional screen-capture permission entry if that matches existing permission architecture.
- `Ora/Permissions/PermissionsManager.swift` - Optional permission refresh/request plumbing for screenshot capture if integrated centrally.

### 5.3 Tests to Add

- `OraTests/Overlay/OverlayViewTests.swift` - Attachment tray rendering and remove behavior.
- `OraTests/Orchestration/SimplePipelineControllerTests.swift` - Pending attachment lifecycle through cancel/reset/submit.
- `OraTests/PermissionsTests.swift` - Screen-capture permission status mapping if added to the shared manager.
- `OraTests/PreferencesViewTests.swift` - Optional permission guidance visibility if surfaced in Preferences.

### 5.4 Dependencies/Config

- No new package dependency beyond ScreenCaptureKit, which is part of macOS.
- If ScreenCaptureKit requires new entitlements or Info.plist text, document them explicitly during implementation.

## 6. Acceptance Criteria

- [ ] AC-1: Users can add a pending image attachment from clipboard, file import, or screenshot capture.
- [ ] AC-2: Pending attachments are visible in the overlay before the turn is submitted and can be removed individually.
- [ ] AC-3: Image files are staged through an app-managed store instead of being held only in transient view state.
- [ ] AC-4: Denied screenshot permission produces clear guidance and does not block clipboard/file-import attachments.
- [ ] AC-5: Cancelling a turn or completing it clears pending attachments from the compose state.

## 7. Verification Plan

### Automated Tests

- [ ] `./build.sh test`
- [ ] Add overlay tests for attachment tray presentation and removal.
- [ ] Add pipeline tests for attachment lifecycle across submit/cancel/reset flows.
- [ ] Add permission tests if screen-capture permission is integrated into the shared permission layer.

### Manual Tests

- [ ] Paste an image from the clipboard and confirm it appears as a pending attachment.
- [ ] Choose an image file and confirm it appears as a pending attachment.
- [ ] Trigger screenshot capture, accept or deny permission, and confirm the resulting guidance and behavior are correct.
- [ ] Remove one pending attachment and then clear all remaining attachments.
- [ ] Cancel a turn while attachments are pending and confirm the compose state resets cleanly.

## 8. Performance / Reliability Considerations

- Attachment previews should use thumbnails or bounded-size images, not full-resolution image decoding in the main view hierarchy.
- Staged attachment files need cleanup rules so the app does not accumulate unbounded image storage over time.
- Screenshot capture should avoid long-lived capture sessions; this story is about static screenshots only.

## 9. Risks & Mitigations

- Screenshot permission UX can feel heavy-handed
  - Mitigation: keep screenshot optional and preserve clipboard/file import as low-friction alternatives.

- Large images can bloat memory or preview rendering
  - Mitigation: stage originals on disk and derive smaller preview thumbnails for UI.

- Overlay clutter from too many controls
  - Mitigation: keep attachment actions compact and secondary to the existing voice-first control.

## 10. Open Questions

- Should the screenshot action capture a user-selected region, a chosen window, or the full display in the first version? The story assumes ScreenCaptureKit is used, but the exact initial capture mode should be decided during implementation based on API ergonomics and permission flow.

---

## Implementation Summary

**Date:** 2026-03-06
**Branch:** `feat/V.03-image-attachments`
**Commits:** 4
**Implemented by:** codex (complexity score: 10/10)
**Reviewed by:** codex (3 iterations)

### Files Changed
- `Ora/LLM/AttachmentStore.swift` - Created: actor-backed attachment staging store with cleanup
- `Ora/Overlay/AttachmentTrayView.swift` - Created: pending attachment chips/previews with remove actions
- `Ora/Utilities/ScreenshotCaptureService.swift` - Created: ScreenCaptureKit screenshot helper with permission mapping
- `Ora/Overlay/OverlayState.swift` - Modified: added pending attachment tracking
- `Ora/Overlay/OverlayView.swift` - Modified: renders attachment tray above voice controls
- `Ora/Overlay/VoiceInputControlView.swift` - Modified: added attachment action affordances
- `Ora/Orchestration/SimplePipelineController.swift` - Modified: holds/clears pending attachments through turn lifecycle
- `Ora/Orchestration/SimplePipelineController+Agent.swift` - Modified: cleanup on failed/cancelled turns
- `Ora/Orchestration/AgentLoop.swift` - Modified: passes attachments into LLM turn
- `Ora/Orchestration/ConfirmationHandler.swift` - Modified: attachment context awareness
- `Ora/Preferences/Tabs/PermissionsPreferencesView.swift` - Modified: screenshot permission guidance
- `OraTests/LLM/AttachmentStoreTests.swift` - Created: staging and cleanup tests
- `OraTests/Orchestration/SimplePipelineControllerAttachmentTests.swift` - Created: lifecycle tests
- `OraTests/Overlay/OverlayViewTests.swift` - Created: tray rendering tests
- `OraTests/ScreenshotCaptureServiceTests.swift` - Created: permission error mapping tests
- `OraTests/Orchestration/AgentLoopTests.swift` - Modified: attachment pass-through tests
- `OraTests/Orchestration/MockPipelineDependencies.swift` - Created: mock helpers

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-03-06T06:54:55Z
**Commit reviewed:** e67cacf
**Iteration:** 3

### Summary
- Files reviewed: 18
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [x] None.

#### P1 - Major (Should fix)
- [x] None.

#### P2 - Minor (Can defer)
- [x] None.

### Future Considerations (Out of Scope)
- None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
