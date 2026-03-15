# BG.08 - Task Progress UI

**Epic:** Background Tasks
**Status:** Draft
**Priority:** P2 (Medium)
**Estimated Effort:** 2 days
**Dependencies:** BG.01, BG.06
**Target:** macOS 26 (Tahoe)

## Summary

Add visual feedback for background research tasks so the user can see that work is happening, track progress, and interact with results — without relying solely on voice queries or waiting for a completion notification. The design uses two tiers: an **in-app menu bar progress indicator** for real-time status and **replace-in-place system notifications** for lifecycle milestones.

## Architecture Context and Reuse Guidance

- Ora already owns an `NSStatusItem` managed by [StatusBarController.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/UI/StatusBarController.swift).
- Background task events are published via `BackgroundTaskManager.observe() -> AsyncStream<BackgroundTaskEvent>` (BG.01).
- Completion/failure notifications are already handled by `TaskNotificationService` (BG.06); this story extends, not replaces, that behavior.
- The overlay window is managed by [OverlayWindowController.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/UI/OverlayWindowController.swift).

## Platform Research Summary

| Approach | macOS Support | Verdict |
|:---------|:-------------|:--------|
| `NSStatusItem` + custom `NSMenu` views | 10.10+ | **Primary approach** — full control, no permissions needed |
| `UNUserNotificationCenter` replace-in-place (same identifier) | 10.14+ | **Secondary** — for completion/failure only |
| Notification Content Extensions (`UNNotificationContentExtension`) | 11.0+ (limited UX on macOS) | **Skip** — high cost, uncertain macOS behavior |
| Live Activities / ActivityKit | **Not available on macOS** | **Skip** — iOS/iPadOS only |
| `NSUserNotificationCenter` | Deprecated macOS 11 | **Skip** |

Key API notes:
- **No progress bars in system notifications.** Text replacement only.
- **`NSMenuItem.view`** accepts any `NSView` including `NSHostingView` for SwiftUI content and `NSProgressIndicator`.
- **`UNNotificationRequest` with same identifier replaces in-place** — use for lifecycle updates without notification spam.
- **`threadIdentifier`** groups all Ora task notifications together in Notification Center.
- **`interruptionLevel`** (macOS 12+): use `.passive` for progress updates, `.active` for completion.

## Resolved Decisions

- Menu bar progress is the primary UX; it requires no permissions and provides real-time updates.
- System notifications remain for completion/failure only (BG.06 scope), not progress.
- No new preferences UI in this story.
- The overlay gets a compact task status line, not a full task browser.

## File Touch List

- `Ora/UI/TaskProgress/TaskProgressMenuItems.swift`
  Purpose: custom `NSMenuItem` views showing active task progress in the status bar menu.
- `Ora/UI/TaskProgress/TaskProgressObserver.swift`
  Purpose: subscribes to `BackgroundTaskManager.observe()` and maintains a view model of active tasks.
- `Ora/UI/StatusBarController.swift`
  Purpose: integrate task progress section into the existing menu.
- `Ora/UI/Overlay/OverlayTaskStatusView.swift`
  Purpose: compact task status line shown in the overlay when tasks are active.
- `Ora/UI/Overlay/OverlayWindowController.swift`
  Purpose: conditionally show/hide the task status line.
- `Ora/BackgroundTasks/Notifications/TaskNotificationService.swift`
  Purpose: add replace-in-place notification updates for task lifecycle and thread grouping.
- `OraTests/UI/TaskProgressObserverTests.swift`
- `OraTests/UI/TaskProgressMenuItemsTests.swift`

## Implementation Steps

### Tier 1: Menu Bar Progress

1. Implement `TaskProgressObserver`.
   - Subscribe to `BackgroundTaskManager.observe()`.
   - Maintain a `@Published` list of active tasks with state, label, and progress phase.
   - Progress phases: `queued` → `fetching (N/M URLs)` → `summarizing` → `done`.
   - Expose `hasActiveTasks: Bool` for status bar icon changes.

2. Implement `TaskProgressMenuItems`.
   - Custom `NSMenuItem` with an embedded `NSHostingView` (SwiftUI) or `NSView`:
     - Task label (or "Research: <first URL host>")
     - Current phase text (e.g., "Fetching 2 of 3 URLs...")
     - `NSProgressIndicator` (indeterminate spinner for phases without granular progress, determinate bar for URL fetch count)
     - Cancel button per task
   - When no tasks are active, the section is hidden.
   - When tasks are active, section appears above existing menu items with a separator.

3. Update `StatusBarController`.
   - Add a dynamic menu section for active tasks.
   - Animate the status bar icon while tasks are running:
     - Idle: normal Ora icon
     - Active: subtle activity indicator (e.g., rotating SF Symbol `arrow.triangle.2.circlepath` or a pulsing dot overlay)
   - Icon returns to normal when all tasks complete.

### Tier 2: Overlay Status Line

4. Implement `OverlayTaskStatusView`.
   - A compact SwiftUI view shown at the bottom of the overlay when tasks are active:
     ```
     ┌────────────────────────────────────┐
     │  [conversation messages...]        │
     │                                    │
     │  ⟳ Researching 2 URLs...    Cancel │
     └────────────────────────────────────┘
     ```
   - Tapping the status line opens the menu bar dropdown (or a popover with task details).
   - Disappears when no tasks are active.
   - Shows the most recent task if multiple are running; "2 tasks running" if >1.

5. Update `OverlayWindowController` to conditionally include the status line.

### Tier 3: Enhanced Notifications

6. Update `TaskNotificationService` for replace-in-place lifecycle.
   - Use a stable notification identifier per task: `"ora-task-\(taskID.uuidString.prefix(8))"`.
   - Post a notification when task starts: title "Research Started", body "Fetching <label>...", `interruptionLevel: .passive`.
   - Replace in-place when summarizing: body "Summarizing <label>...".
   - Replace with final notification on completion: body "Summary ready", `interruptionLevel: .active`, with "View Summary" action.
   - Set `threadIdentifier = "ora-background-tasks"` on all task notifications for grouping.
   - Add a custom completion sound (short chime, bundled `.caf` file, max 2 seconds).

## Tests and Validation

- `test_observer_tracksActiveTaskLifecycle`
- `test_observer_reportsProgressPhases`
- `test_observer_hasActiveTasks_trueWhenRunning`
- `test_observer_hasActiveTasks_falseWhenAllComplete`
- `test_menuItems_showCancelButton`
- `test_menuItems_hiddenWhenNoActiveTasks`
- `test_overlayStatus_visibleWhenTasksActive`
- `test_overlayStatus_hiddenWhenIdle`
- `test_notification_replaceInPlace_sameIdentifier`
- `test_notification_threadGrouping`

Manual validation:
- Enqueue a research task and observe the menu bar icon change to an activity state.
- Open the menu bar dropdown and see the task with progress and a cancel button.
- Observe the overlay show "Researching..." while the task runs.
- Confirm the menu bar icon returns to normal after task completion.
- Confirm the system notification updates in-place from "Fetching..." to "Summary ready."

## Acceptance Criteria

- [ ] Menu bar icon visually indicates when background tasks are active.
- [ ] Menu bar dropdown shows active tasks with progress phase and cancel action.
- [ ] Overlay shows a compact task status line when tasks are running.
- [ ] Status indicators disappear when all tasks complete.
- [ ] System notifications use replace-in-place updates (same identifier) for task lifecycle.
- [ ] All task notifications are grouped via `threadIdentifier`.
- [ ] No new permissions are required for the menu bar/overlay UI.
- [ ] Cancel action from menu or overlay cancels the task via `BackgroundTaskManager`.

## Risks and Open Questions

- **Menu bar icon animation:** Animating `NSStatusItem` images requires a timer-based frame swap. Keep it subtle (2-3 fps pulse, not a distracting spinner). Test on retina and non-retina displays.
- **Overlay status line layout:** Must not shift conversation content or cause layout jumps. Use a fixed-height slot that's always reserved but visibility-toggled.
- **Notification replace-in-place behavior:** When the user has already dismissed a notification, a replacement creates a new banner. This could be slightly annoying for long tasks. Consider only posting start + completion notifications, skipping intermediate updates.
- **Custom sound:** Must be a short, recognizable chime that doesn't conflict with system sounds. Ship a `.caf` file in the app bundle under `Sounds/`.
