# BG.06 - Local Notifications

**Epic:** Background Tasks
**Status:** Ready for Implementation
**Priority:** P2 (Medium)
**Estimated Effort:** 1.5 days
**Dependencies:** BG.01, BG.04, BG.05
**Target:** macOS 26 (Tahoe)

## Summary

Add optional local notifications for background-task completion and failure. v1 should reuse the lightweight authorization/delivery pattern already used by model migration rather than expanding Ora’s global `PermissionsManager` surface.

## Architecture Context and Reuse Guidance

- Reuse the `UNUserNotificationCenter` authorization style from [ModelMigrationCoordinator.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Models/ModelMigrationCoordinator.swift).
- Do **not** add `.notifications` to `PermissionType` in this story; that would expand setup/preferences scope unnecessarily.
- `AppDelegate` should own `UNUserNotificationCenter.delegate` setup and pending-notification cleanup on termination.
- Finder reveal should reuse the artifact path from BG.04.

## Resolved Decisions

- Notification permission is requested lazily by the background-task notifier itself.
- v1 sends notifications for `completed` and `failed` only.
- Default notification click activates Ora.
- Explicit action button: `Show in Finder`.
- No new Preferences UI in this story.

## File Touch List

- `Ora/BackgroundTasks/Notifications/TaskNotificationService.swift`
  Purpose: authorization + notification scheduling.
- `Ora/BackgroundTasks/Notifications/TaskNotificationDelegate.swift`
  Purpose: handle default click and `Show in Finder`.
- `Ora/BackgroundTasks/BackgroundTaskManager.swift`
  Purpose: invoke notification service on terminal state changes.
- `Ora/AppDelegate.swift`
  Purpose: set `UNUserNotificationCenter.delegate` and clear pending requests on termination.
- `OraTests/BackgroundTasks/TaskNotificationServiceTests.swift`
- `OraTests/BackgroundTasks/TaskNotificationDelegateTests.swift`

## Implementation Steps

1. Implement `TaskNotificationService`.
   Required API:
   - `postCompletion(taskID:title:summaryPreview:artifactPath:)`
   - `postFailure(taskID:title:errorDescription:)`

2. Keep authorization local to the service.
   Behavior:
   - check notification settings
   - request authorization only when first needed
   - fail silently with logging if denied

3. Implement `TaskNotificationDelegate`.
   Required behavior:
   - default click: activate Ora
   - `Show in Finder`: reveal `artifactPath` if present
   - **artifact path validation (SECURITY):** before using `artifactPath` in Finder reveal, validate it points within `~/Documents/Ora Research/` root. Reject paths outside this root.
   - **notification content sanitization:** truncate notification body text to prevent adversarial content from summary previews. Strip control characters.

4. Add notification coalescing.
   If multiple tasks complete within a short window (e.g., 3 seconds), group them into a single notification: "2 research tasks completed" rather than firing 2 separate notifications.

5. Wire delegate registration in `AppDelegate`.

6. Clear pending requests on `applicationWillTerminate`.
   Use `removeAllPendingNotificationRequests()` for undelivered notifications. Optionally also call `removeAllDeliveredNotifications()` to clean Notification Center.

## Tests and Validation

- `test_completionNotification_containsSummaryPreview`
- `test_failureNotification_containsErrorText`
- `test_permissionDenied_skipsDeliveryWithoutFailingTask`
- `test_defaultClick_activatesApp`
- `test_showInFinderAction_revealsArtifactPath`
- `test_pendingNotificationsClearedOnTerminate`
- `test_artifactPathValidation_rejectsPathOutsideRoot`
- `test_notificationCoalescing_groupsRapidCompletions`

Manual validation:
- Complete a task and verify a single completion notification appears.
- Fail a task and verify a failure notification appears.
- Use `Show in Finder` and confirm the artifact folder is revealed.

## Acceptance Criteria

- [ ] Completion and failure notifications are delivered when permission is granted.
- [ ] Permission is requested lazily by the task notification service, not by setup or `PermissionsManager`.
- [ ] Default click activates Ora.
- [ ] `Show in Finder` reveals the saved artifact folder when available.
- [ ] Denied notification permission does not break task execution.
- [ ] `AppDelegate` clears pending requests on termination.

## Risks and Open Questions

- If a richer in-app task browser is added later, notification default-click behavior can be upgraded without invalidating this v1 contract.
