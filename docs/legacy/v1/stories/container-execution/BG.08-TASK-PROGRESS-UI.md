# BG.08 - Task Progress UI

**Epic:** Background Tasks
**Status:** ✅ Complete
**Priority:** P2 (Medium)
**Estimated Effort:** 2 days
**Dependencies:** BG.01, BG.06
**Target:** macOS 26 (Tahoe)

## Summary

Add visual feedback for background research tasks so the user can see that work is happening, track progress, and interact with results without relying solely on voice queries or a completion notification. The shipped design uses two tiers: an **in-app menu bar progress indicator** for real-time status and a **compact overlay status line** backed by the same observer. Notifications remain terminal-only, but now use stable identifiers and `threadIdentifier` grouping.

## Verification Notes

- Implemented on 2026-03-16.
- `xcodebuild test` focused BG.08 slice passed: `55/55`.
- `./build.sh run` succeeded after the BG.08 implementation pass.

## Architecture Context and Reuse Guidance

- Ora already owns an `NSStatusItem` managed by [StatusBarController.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/UI/StatusBarController.swift).
- Background task events are published via `BackgroundTaskManager.observe() -> AsyncStream<BackgroundTaskEvent>` (BG.01).
- Summary progress is surfaced via `BackgroundTaskRecord.summaryState`; `BackgroundTaskManager.updateSummaryState(...)` now emits observer events so UI can display `summarizing`.
- Completion/failure notifications are already handled by `TaskNotificationService` (BG.06); BG.08 only hardens identifiers/grouping for that terminal path.
- The overlay window is managed by [OverlayWindowController.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Overlay/OverlayWindowController.swift).

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
- Progress phases are derived from existing queue state, not per-URL fetch metrics: `queued`, `fetching`, `summarizing`.
- System notifications remain completion/failure only (BG.06 scope), not live progress.
- No new preferences UI in this story.
- The overlay gets a compact task status line, not a full task browser.

## File Touch List

- `Ora/UI/TaskProgress/TaskProgressMenuItems.swift`
  Purpose: build the dynamic background-task section in the existing status bar menu.
- `Ora/UI/TaskProgress/TaskProgressObserver.swift`
  Purpose: subscribes to `BackgroundTaskManager.observe()` and maintains a view model of active tasks.
- `Ora/UI/StatusBarController.swift`
  Purpose: integrate task progress section into the existing menu.
- `Ora/Overlay/OverlayTaskStatusView.swift`
  Purpose: compact task status line shown in the overlay when tasks are active.
- `Ora/Overlay/OverlayWindowController.swift`
  Purpose: conditionally show/hide the task status line.
- `Ora/BackgroundTasks/Notifications/TaskNotificationService.swift`
  Purpose: use stable per-task identifiers and `threadIdentifier` grouping for terminal notifications.
- `OraTests/UI/TaskProgressObserverTests.swift`
- `OraTests/UI/TaskProgressMenuItemsTests.swift`

## Implementation Steps

### Tier 1: Menu Bar Progress

1. Implement `TaskProgressObserver`.
   - Subscribe to `BackgroundTaskManager.observe()`.
   - Maintain a `@Published` list of active tasks with label, phase, and detail text.
   - Map lifecycle into UI phases: `queued` → `fetching` → `summarizing`.
   - Expose `hasActiveTasks`, `primaryTask`, `statusLineText`, and cancel helpers.

2. Implement `TaskProgressMenuItems`.
   - Add a menu section header, one status row per active task, and one cancel row per task.
   - Hide the section when no tasks are active.
   - Insert the section above the existing model/preferences items.

3. Update `StatusBarController`.
   - Subscribe to `TaskProgressObserver.$activeTasks`.
   - Add a dynamic menu section for active tasks.
   - Switch the idle icon to an activity symbol while background tasks are active.
   - Route cancel clicks back through `BackgroundTaskManager.cancel(...)`.

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

5. Update `OverlayWindowController` to inject the shared task observer into `OverlayView`.

### Tier 3: Enhanced Notifications

6. Update `TaskNotificationService`.
   - Use a stable notification identifier per task: `"ora-task-\(taskID.uuidString.lowercased())"`.
   - Set `threadIdentifier = "ora-background-tasks"` on completion/failure notifications.
   - Keep notifications terminal-only for v1.

## Tests and Validation

- `test_observer_tracksActiveTaskLifecycle`
- `test_observer_reportsQueuedAndFetchingPhases`
- `test_observer_reportsSummarizingPhase`
- `test_cancelPrimaryTask_cancelsManagerTask`
- `test_menuItems_showCancelButton`
- `test_menuItems_hiddenWhenNoActiveTasks`
- `test_notification_replaceInPlace_sameIdentifier`
- `test_notification_threadGrouping`
- `test_menuItemTitles_includeBackgroundTaskSectionWhenActive`

Manual validation:
- Enqueue a research task and observe the menu bar icon change to the activity symbol while Ora is otherwise idle.
- Open the menu bar dropdown and see the task section with phase text and a cancel action.
- Observe the overlay show the compact task status line while the task runs.
- Confirm the menu bar icon and overlay status line both clear after task completion.
- Confirm completion and failure notifications share stable per-task identifiers and a common `threadIdentifier`.

## Acceptance Criteria

- [x] Menu bar icon visually indicates when background tasks are active.
- [x] Menu bar dropdown shows active tasks with progress phase and cancel action.
- [x] Overlay shows a compact task status line when tasks are running.
- [x] Status indicators disappear when all tasks complete.
- [x] System notifications use stable per-task identifiers on terminal delivery.
- [x] All task notifications are grouped via `threadIdentifier`.
- [x] No new permissions are required for the menu bar/overlay UI.
- [x] Cancel action from menu or overlay cancels the task via `BackgroundTaskManager`.

## Risks and Open Questions

- **Granular progress:** v1 still lacks per-URL fetch counts. Progress is phase-based only.
- **Overlay layout:** the compact status line is conditional, so it slightly changes available transcript height while tasks are active.
- **Notification replacement:** terminal notifications now use stable identifiers, but v1 intentionally does not post intermediate lifecycle banners.
