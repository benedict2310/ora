# BG.06 - Local Notifications

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P2 (Medium)
**Estimated Effort:** 1.5 days
**Dependencies:** BG.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** BG.00

---

## 1. Objective

Notify the user when background tasks start and complete using macOS local notifications (`UNUserNotificationCenter`). Completion notifications include a summary preview and action buttons to open Ora or reveal results in Finder.

## 2. User Story

As a **user**, I want to be **notified when background research completes** so that I can **review results at my convenience without watching Ora**.

## 3. Scope

### In Scope

- `TaskNotificationService` actor for managing local notifications
- Notification permission request (new optional permission)
- "Task Started" notification with task description
- "Task Completed" notification with summary preview (first 100 chars of summary)
- "Task Failed" notification with error description
- Action buttons: "Open in Ora", "Show in Finder"
- Notification grouping by thread identifier (all Ora background task notifications grouped)
- `UNUserNotificationCenterDelegate` handling for action button routing
- Graceful degradation: if notification permission denied, log and continue silently

### Out of Scope

- Push notifications (no server component)
- Notification preferences UI (future: per-task-type notification settings)
- Sound customization
- Badge count on Dock icon
- Rich media attachments (images, thumbnails)
- Integration with setup wizard (defer permission request to first background task)

## 4. Architecture Alignment

### Component Placement

```
Ora/BackgroundTasks/
  ├── Notifications/
  │   ├── TaskNotificationService.swift   // Actor: schedule/manage notifications
  │   └── TaskNotificationDelegate.swift  // UNUserNotificationCenterDelegate
  └── ... (existing from BG.01)

Ora/Permissions/
  └── NotificationPermission.swift        // New permission type
```

### Notification Types

| Type | Title | Body | Actions |
|:-----|:------|:-----|:--------|
| Started | "Research Started" | Task description (e.g., "Researching Swift concurrency...") | None |
| Completed | "Research Complete" | Summary preview (first 100 chars) | "Open in Ora", "Show in Finder" |
| Failed | "Research Failed" | Error description | "Open in Ora" |

### Notification Identifiers

```swift
enum TaskNotificationCategory: String {
    case taskStarted = "com.ora.task.started"
    case taskCompleted = "com.ora.task.completed"
    case taskFailed = "com.ora.task.failed"
}

enum TaskNotificationAction: String {
    case openInOra = "com.ora.action.open"
    case showInFinder = "com.ora.action.finder"
}

// Thread identifier groups all background task notifications
let backgroundTaskThread = "com.ora.background-tasks"
```

### Action Routing

```
User taps "Open in Ora"
  → UNUserNotificationCenterDelegate.didReceive(response:)
  → Extract taskID from notification userInfo
  → Post NotificationCenter: .backgroundTaskOpenRequested(taskID)
  → SimplePipelineController / overlay shows task context

User taps "Show in Finder"
  → UNUserNotificationCenterDelegate.didReceive(response:)
  → Extract taskID from notification userInfo
  → ArtifactStore.revealInFinder(taskID:)
```

### Permission Integration

Notification permission follows the existing `PermissionsManager` pattern:
- Check via `UNUserNotificationCenter.current().notificationSettings()`
- Request via `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`
- Status mapped to existing `PermissionStatus` enum (.authorized, .denied, .notDetermined)
- Permission requested lazily on first background task trigger (not during setup wizard)

### Integration Points

| Component | Integration |
|:----------|:------------|
| `BackgroundTaskManager` | Calls `TaskNotificationService` on task state changes |
| `ArtifactStore` (BG.04) | "Show in Finder" action opens artifact folder |
| `SummaryGenerator` (BG.05) | Summary preview included in completion notification |
| `PermissionsManager` | New `.notifications` permission type |
| `AppDelegate` / `main.swift` | Set `UNUserNotificationCenter.delegate` at launch |

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/BackgroundTasks/Notifications/TaskNotificationService.swift` — Schedule start/complete/fail notifications
- `Ora/BackgroundTasks/Notifications/TaskNotificationDelegate.swift` — Handle action button responses
- `Ora/Permissions/NotificationPermission.swift` — Permission check/request for UNUserNotificationCenter
- `OraTests/BackgroundTasks/TaskNotificationServiceTests.swift` — Unit tests
- `OraTests/Permissions/NotificationPermissionTests.swift` — Permission tests

### 5.2 Files to Modify

- `Ora/Permissions/PermissionsManager.swift` — Add `.notifications` permission type
- `Ora/Permissions/PermissionType.swift` — Add `.notifications` case
- `Ora/BackgroundTasks/BackgroundTaskManager.swift` — Call `TaskNotificationService` on state changes
- `Ora/main.swift` or `AppDelegate` — Set `UNUserNotificationCenter.delegate` early in app lifecycle

### 5.3 Tests to Add

- `OraTests/BackgroundTasks/TaskNotificationServiceTests.swift`:
  - `test_scheduleStartNotification_setsCorrectContent`
  - `test_scheduleCompletionNotification_includesSummaryPreview`
  - `test_scheduleFailureNotification_includesErrorDescription`
  - `test_completionNotification_hasActionButtons`
  - `test_notifications_groupedByThreadIdentifier`
  - `test_permissionDenied_logsAndContinues`
  - `test_summaryPreview_truncatedAt100Chars`
  - `test_removeAll_clearsPendingNotifications`
- `OraTests/Permissions/NotificationPermissionTests.swift`:
  - `test_checkStatus_mapsUNAuthorizationStatus`
  - `test_request_callsUNAuthorization`
  - `test_notDetermined_returnsCorrectStatus`

### 5.4 Dependencies/Config

- `project.yml` — Ensure `UserNotifications` framework is linked (should already be available on macOS 26)
- No new SPM dependencies

## 6. Acceptance Criteria

- [ ] AC-1: "Research Started" notification delivered when task begins execution
- [ ] AC-2: "Research Complete" notification delivered with summary preview when task succeeds
- [ ] AC-3: "Research Failed" notification delivered with error when task fails
- [ ] AC-4: "Open in Ora" action brings Ora to foreground and shows task context
- [ ] AC-5: "Show in Finder" action reveals artifact folder in Finder
- [ ] AC-6: All background task notifications grouped under single thread
- [ ] AC-7: Notification permission requested lazily on first background task (not during setup)
- [ ] AC-8: If notification permission denied, tasks still execute normally (silent mode)
- [ ] AC-9: Summary preview truncated to 100 characters with ellipsis
- [ ] AC-10: Pending notifications cleared on app termination

## 7. Verification Plan

### Automated Tests

- [ ] Notification content tests (title, body, category, actions, thread ID, userInfo)
- [ ] Permission check/request tests (mock UNUserNotificationCenter)
- [ ] Action routing tests (delegate receives response, posts correct internal notification)
- [ ] Graceful degradation test (permission denied, no crash, task completes normally)
- [ ] Summary preview truncation test (exactly 100 chars, with ellipsis)

### Manual Tests

- [ ] Trigger background task and verify "Started" notification appears in Notification Center
- [ ] Wait for task completion and verify "Complete" notification with summary preview
- [ ] Tap "Open in Ora" notification action and verify app comes to foreground
- [ ] Tap "Show in Finder" notification action and verify correct folder opens
- [ ] Deny notification permission and verify tasks still work silently
- [ ] Trigger multiple tasks and verify notifications are grouped in Notification Center

## 8. Performance / Reliability Considerations

- Notification scheduling is lightweight (under 1ms per call)
- `UNUserNotificationCenter` handles delivery timing; no polling needed
- Delegate must be set early in app lifecycle (before any notifications fire)
- No impact on conversation pipeline performance
- Max 2 notifications per task (start + end) prevents notification flood

## 9. Risks & Mitigations

- **Notification permission fatigue** — Make permission optional; request lazily on first background task, not during setup wizard
- **Stale notifications after app quit** — Remove pending notifications on app termination via `removeAllPendingNotificationRequests()`
- **Action button handling after app restart** — `UNUserNotificationCenterDelegate` is set on app launch; pending actions delivered on next activation
- **Notification overload from many tasks** — Group by thread identifier; max 2 notifications per task

## 10. Open Questions

- Should "Task Started" notifications be optional/configurable? (Proposed: yes, default on; some users may find them noisy)
- Should notifications include a progress indicator for long tasks? (Proposed: not in v1 — macOS doesn't support inline progress in notifications)
- Should we add a "Notifications" section to Preferences? (Proposed: future — not needed for v1)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
