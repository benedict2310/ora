# BG.01 - Task Queue

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** BG.00

---

## 1. Objective

Create a persistent task queue inside Ora with lifecycle management, concurrency control, and timeout enforcement. This is the foundation for all background task execution.

## 2. User Story

As a **developer**, I want a **reliable task queue** so that **background tasks are tracked, persisted, and executed with proper lifecycle management**.

## 3. Scope

### In Scope

- SwiftData-persisted task model with full state machine
- `BackgroundTaskManager` actor with enqueue/cancel/query API
- Concurrency limit enforcement (configurable, default: 2)
- Timeout enforcement per task (configurable, default: 120s)
- Task cancellation (user-initiated and app-quit)
- Task state observation via `AsyncStream` for UI/notification consumers
- Audit logging of task lifecycle events

### Out of Scope

- Worker execution (BG.02)
- Network policy (BG.03)
- Artifact storage (BG.04)
- Notifications (BG.06)
- Task persistence across app restarts (v1 — tasks are canceled on quit)
- Task scheduling / cron

## 4. Architecture Alignment

### Component Placement

```
Ora/BackgroundTasks/
  ├── BackgroundTask.swift              // SwiftData model
  ├── BackgroundTaskManager.swift       // Actor: queue management
  ├── BackgroundTaskPolicy.swift        // Timeout, limits, domain rules
  └── BackgroundTaskState.swift         // State machine enum
```

### Concurrency Model

- `BackgroundTaskManager` is an **actor** (consistent with `ToolHost`, `ToolRegistry`, `LLMService`)
- Task execution dispatched as Swift Concurrency `Task` instances
- Running tasks tracked in a dictionary for cancellation
- State changes published via `AsyncStream<BackgroundTaskEvent>` for observers

### Integration Points

| Existing Component | Integration |
|:-------------------|:------------|
| `ToolRegistry` | Register `research.start` tool (BG.02) |
| `AuditLogger` | Log task lifecycle events |
| `SimplePipelineController` | Cancel all tasks on app quit |
| SwiftData (`ModelContainer`) | Reuse existing persistence container |

### Guardrails

- Maximum queue depth: 10 tasks (reject beyond this)
- Maximum concurrent workers: 2 (configurable)
- Per-task timeout: 120s default, 300s max
- Enqueue validation: reject invalid URLs, empty inputs

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/BackgroundTasks/BackgroundTask.swift` — SwiftData `@Model` with id, type, inputs, policy, state, timestamps, error, artifactPath, sessionID
- `Ora/BackgroundTasks/BackgroundTaskState.swift` — Enum: `queued`, `running`, `succeeded`, `failed`, `canceled` with valid transitions
- `Ora/BackgroundTasks/BackgroundTaskPolicy.swift` — Struct: timeoutSeconds, maxResponseBytes, allowedDomains, maxRequests
- `Ora/BackgroundTasks/BackgroundTaskInputs.swift` — Struct: urls, query, taskType
- `Ora/BackgroundTasks/BackgroundTaskManager.swift` — Actor with enqueue/cancel/query/observe API
- `Ora/BackgroundTasks/BackgroundTaskEvent.swift` — Enum for state change events
- `OraTests/BackgroundTasks/BackgroundTaskManagerTests.swift` — Unit tests

### 5.2 Files to Modify

- `Ora/Persistence/PersistenceController.swift` — Add `BackgroundTask` to SwiftData model container
- `Ora/Orchestration/SimplePipelineController.swift` — Cancel background tasks on app quit (`cancelAllTasks()`)
- `project.yml` — Add `Ora/BackgroundTasks/` to sources

### 5.3 Tests to Add

- `OraTests/BackgroundTasks/BackgroundTaskManagerTests.swift`:
  - `test_enqueue_createsTaskInQueuedState`
  - `test_enqueue_rejectsWhenQueueFull`
  - `test_cancel_movesTaskToCanceledState`
  - `test_cancelAll_cancelsAllRunningAndQueuedTasks`
  - `test_concurrencyLimit_queuesExcessTasks`
  - `test_timeout_failsTaskAfterDeadline`
  - `test_stateTransitions_rejectsInvalidTransitions`
  - `test_observe_emitsStateChangeEvents`
  - `test_dequeue_startsNextQueuedTaskWhenSlotAvailable`

### 5.4 Dependencies/Config

- `project.yml` — Add `Ora/BackgroundTasks/` source group

## 6. Acceptance Criteria

- [ ] AC-1: `BackgroundTask` SwiftData model persists with all required fields (id, type, inputs, policy, state, timestamps)
- [ ] AC-2: State machine enforces valid transitions only (queued→running, running→succeeded/failed/canceled, queued→canceled)
- [ ] AC-3: `BackgroundTaskManager.enqueue()` creates task and starts execution when a slot is available
- [ ] AC-4: Concurrency limit prevents more than N tasks running simultaneously
- [ ] AC-5: Tasks exceeding timeout are automatically moved to `failed` state
- [ ] AC-6: `cancelAll()` cancels all queued and running tasks (called on app quit)
- [ ] AC-7: `observe()` returns an `AsyncStream` that emits task state change events
- [ ] AC-8: Queue depth limit (10) rejects new tasks with descriptive error
- [ ] AC-9: Task lifecycle events logged via `AuditLogger`

## 7. Verification Plan

### Automated Tests

- [ ] State machine transition tests (all valid/invalid paths)
- [ ] Concurrency limit enforcement test
- [ ] Timeout enforcement test (use short timeout in test)
- [ ] Cancel propagation test
- [ ] Queue depth limit test
- [ ] Event stream emission test

### Manual Tests

- [ ] Trigger multiple research tasks and verify only 2 run concurrently
- [ ] Quit Ora while tasks are running and verify all are canceled
- [ ] Verify task records persist in SwiftData during app session

## 8. Performance / Reliability Considerations

- Task queue operations must be O(1) for enqueue, O(n) for cancelAll where n is active tasks
- SwiftData writes are batched (save after state transitions, not on every field change)
- `AsyncStream` for observation uses buffering policy `.bufferingNewest(10)` to avoid backpressure
- Memory: task model is lightweight (~1KB per task); 10 tasks = negligible

## 9. Risks & Mitigations

- **SwiftData thread safety** — All access through `BackgroundTaskManager` actor; no direct model context sharing
- **Task leak on crash** — v1 accepts this; tasks don't survive app restart. Future: mark stale tasks on launch
- **Timeout race condition** — Use `Task.sleep` with cancellation check; timeout task cancels worker task

## 10. Open Questions

- Should failed tasks be retryable? (Proposed: not in v1, add in future)
- Should the queue persist across app restarts? (Proposed: no for v1 — tasks are lightweight and re-triggerable)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
