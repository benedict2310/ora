# BG.01 - Task Queue

**Epic:** Background Tasks
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** BG.00
**Target:** macOS 26 (Tahoe)

## Summary

Implement the persistent queue and lifecycle layer for background research jobs. `BackgroundTaskManager` owns enqueue, cancellation, bounded concurrency, timeout handling, observer streams, and launch-time reconciliation of stale tasks. v1 persists task records in SwiftData but never resumes unfinished work after relaunch.

## Verification Notes

- Verified on 2026-03-16 against [BackgroundTaskManager.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/BackgroundTaskManager.swift), [BackgroundTaskRecord.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/BackgroundTasks/BackgroundTaskRecord.swift), [PersistenceManager.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Persistence/PersistenceManager.swift), and [AppDelegate.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/AppDelegate.swift).
- Focused tests passed in `.artifacts/BGTests-2.xcresult`, including `BackgroundTaskManagerTests`.

## Architecture Context and Reuse Guidance

- Reuse [PersistenceManager.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Persistence/PersistenceManager.swift) for the SwiftData container and schema registration. Do **not** create a parallel persistence controller.
- App lifecycle hooks belong in [AppDelegate.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/AppDelegate.swift), not in `SimplePipelineController`.
- Keep queue orchestration in an actor, matching existing patterns in `ToolRegistry`, `ToolHost`, and `LLMService`.
- `project.yml` already includes the whole `Ora` tree, so new Swift files under `Ora/BackgroundTasks/` do not require source-list changes.

## Resolved Decisions

- Persisted task model name: `BackgroundTaskRecord`.
- Unfinished tasks (`queued` / `running`) are marked `canceled` on next launch with a reason like `"Ora quit before task completed."`
- Queue depth limit: `10`.
- Concurrent workers: default `2`, injected for tests.
- Task timeout: default `120s`, max `300s`.

## File Touch List

- `Ora/BackgroundTasks/BackgroundTaskRecord.swift`
  Purpose: SwiftData `@Model` for persisted task metadata and state.
- `Ora/BackgroundTasks/BackgroundTaskState.swift`
  Purpose: strongly typed lifecycle enum plus transition validation helpers.
- `Ora/BackgroundTasks/BackgroundTaskInputs.swift`
  Purpose: codable payload for requested `urls` and optional user-facing label/query.
- `Ora/BackgroundTasks/BackgroundTaskPolicy.swift`
  Purpose: codable task policy values shared with worker and artifact stories.
- `Ora/BackgroundTasks/BackgroundTaskEvent.swift`
  Purpose: observer stream payloads for queue/UI/notification consumers.
- `Ora/BackgroundTasks/BackgroundTaskManager.swift`
  Purpose: actor that persists records, schedules work, cancels jobs, and emits events.
- `Ora/Persistence/PersistenceManager.swift`
  Purpose: add `BackgroundTaskRecord` to both production and test schemas.
- `Ora/AppDelegate.swift`
  Purpose: initialize the queue after setup completes, reconcile stale tasks on launch, cancel all tasks on termination.
- `OraTests/BackgroundTasks/BackgroundTaskManagerTests.swift`
  Purpose: queue/lifecycle/concurrency/timeout/reconciliation coverage.

## Implementation Steps

1. Add `BackgroundTaskRecord` as a SwiftData model.
   Required fields:
   - `id: UUID`
   - `taskKind: String`
   - `inputsData: Data`
   - `policyData: Data`
   - `stateRawValue: String`
   - `summaryStateRawValue: String?` (initially `nil`; set to `pending` by BG.05 when summary is enqueued after artifacts are written)
   - `artifactPath: String?`
   - `errorMessage: String?`
   - `createdAt`, `startedAt`, `completedAt`
   - `sessionID: UUID?`

2. Add codable value types for `BackgroundTaskInputs` and `BackgroundTaskPolicy`.
   v1 inputs:
   - `urls: [String]`
   - `label: String?` for notification text / list display

3. Extend `PersistenceManager` schema registration for the new model in both initializers.

4. Implement `BackgroundTaskManager` as the only write owner for task lifecycle.
   Responsibilities:
   - `enqueue(inputs:policy:sessionID:)`
   - `cancel(taskID:)`
   - `cancelAll()`
   - `task(id:)`
   - `list(limit:)`
   - `observe() -> AsyncStream<BackgroundTaskEvent>`
   - `recoverUnfinishedTasksOnLaunch()`

5. Use the `@ModelActor` macro for `BackgroundTaskManager` to get a properly isolated `ModelContext`.
   This follows the existing `BackgroundPersistenceActor` pattern in the codebase. Do **not** create a raw `ModelContext(container)` inside a regular actor — this violates Swift 6 sendability rules.
   Requirement: do not bounce queue state writes through the main actor for normal operation.

6. Add launch and termination hooks in `AppDelegate`.
   - After setup: initialize manager and call `recoverUnfinishedTasksOnLaunch()`.
   - On terminate: `await cancelAll()` before `PersistenceManager.shared.flushSave()`.
   - **Async termination bridging:** `applicationWillTerminate` is synchronous on AppKit. Bridge async cleanup with a synchronous flush path (e.g., `DispatchSemaphore`-based bridging or a dedicated synchronous `cancelAllSync()` method). Do **not** use `ProcessInfo.performExpiringActivity` — it is iOS/Catalyst only.

7. For BG.01 only, worker dispatch can be a stubbed hook.
   The manager must still transition queued tasks to running/completed in tests via an injected executor.

## Tests and Validation

- `test_enqueue_createsQueuedRecord`
- `test_enqueue_rejectsEmptyURLList`
- `test_enqueue_rejectsWhenQueueIsFull`
- `test_runningCount_neverExceedsConcurrencyLimit`
- `test_timeout_movesTaskToFailed`
- `test_cancelQueuedTask_movesToCanceled`
- `test_cancelRunningTask_movesToCanceled`
- `test_observe_emitsLifecycleEventsInOrder`
- `test_recoverUnfinishedTasksOnLaunch_marksQueuedAndRunningAsCanceled`
- `test_cancelAll_marksActiveAndQueuedTasksCanceled`

Manual validation:
- Enqueue several stub tasks and confirm only `N` run concurrently.
- Quit and relaunch with a seeded `running` task and confirm it is reconciled to `canceled`.

## Acceptance Criteria

- [x] `BackgroundTaskRecord` is part of the SwiftData schema used by `PersistenceManager`.
- [x] `BackgroundTaskManager.enqueue()` persists a queued record and starts work when capacity exists.
- [x] Queue depth and timeout limits are enforced.
- [x] `observe()` emits deterministic lifecycle events suitable for UI/notification consumers.
- [x] `cancel()` and `cancelAll()` transition tasks to `canceled` and stop in-flight work.
- [x] Launch reconciliation marks stale unfinished tasks as `canceled`; v1 does not resume them.
- [x] `AppDelegate` owns queue startup and termination hooks.

## Resolved v1 Decisions (from review)

- `summaryStateRawValue` is `nil` on creation; set to `pending` only when BG.05 enqueues a summary job after artifacts are written.
- `BackgroundTaskManager` **must** use the `@ModelActor` macro (matching `BackgroundPersistenceActor` pattern), not a raw actor with a stored `ModelContext`.

## Risks and Open Questions

- The only intentionally deferred behavior is worker execution, which is implemented in BG.02.
- Retry semantics are out of scope for v1; failures remain terminal.
