# BG.06 - Notifications

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** BG.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Notify users when background tasks start and complete, with quick actions to open results.

## 2. User Story

As a user, I want to be notified when a background task finishes so I can review results without manually checking.

## 3. Scope

### In Scope

- Notification on task start
- Notification on task completion
- Actions: “Open in Ora” and “Show in Finder”
- Failure notification with error summary

### Out of Scope

- Scheduling or repeating notifications
- Push notifications
- Notification grouping rules (use defaults)

## 4. Architecture Alignment

- **Component:** `NotificationService` (wrapper around `UNUserNotificationCenter`)
- **Triggers:** `BackgroundTaskManager` state transitions

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/BackgroundTasks/NotificationService.swift`

### 5.2 Files to Modify

- `Ora/BackgroundTasks/BackgroundTaskManager.swift`
- `Ora/AppDelegate.swift` (notification authorization flow)

### 5.3 Tests to Add

- `OraTests/BackgroundTasks/NotificationServiceTests.swift`

## 6. Acceptance Criteria

- [ ] AC-1: Start notifications fire when tasks enter `running`.
- [ ] AC-2: Completion notifications fire when tasks enter `succeeded`.
- [ ] AC-3: Failure notifications include a short error summary.
- [ ] AC-4: Notifications include actions for opening results.

## 7. Verification Plan

### Automated Tests

- Verify `NotificationService` builds the correct payload.
- Verify state transitions trigger notifications.

### Manual Tests

- Start a background task and confirm start/complete notifications appear.

## 8. Performance / Reliability Considerations

- Ensure notifications are throttled to avoid spam.
- Avoid blocking task execution if notifications fail.

## 9. Risks & Mitigations

- **Risk:** Notifications disabled. **Mitigation:** Provide a fallback UI surface in Ora.

## 10. Open Questions

- Should notifications be opt-in with a settings toggle?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
