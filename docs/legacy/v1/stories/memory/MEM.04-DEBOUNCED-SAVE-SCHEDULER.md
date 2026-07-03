# MEM.04 - Debounced Save Scheduler

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** MEM.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Minimize main-actor blocking by debouncing `saveContext()` calls. Currently, every `appendMessage` triggers an immediate `context.save()`. During rapid exchanges (user → assistant → tool → assistant), this causes repeated JSON encode + save cycles on the main actor. A debounced save scheduler coalesces these into fewer saves while still ensuring data survives termination.

## 2. User Story

As a user, I want Ora's UI to remain responsive during conversations so that persistence doesn't cause visible hitching.

## 3. Scope

### In Scope

- Add a debounced save mechanism to `PersistenceManager` using `Task<Void, Never>?`
- On `appendMessage`, schedule a save after 250–500ms (cancel and reschedule if called again within the window)
- Add explicit `flushSave()` for app background/termination
- Wire `flushSave()` into app lifecycle (app delegate termination / `NSApplication.willTerminate`)

### Out of Scope

- Background persistence via ModelActor (MEM.16)
- Migrating away from JSON blob storage (MEM.17)
- Performance instrumentation (MEM.05)

## 4. Architecture Alignment

- **Component:** `Ora/Persistence/PersistenceManager.swift`
- **Concurrency:** All operations remain `@MainActor`. The debounce `Task` runs on MainActor.
- **Current behavior:** `saveContext()` is private and called after every mutation. This story makes it debounced by default with an explicit flush path.
- **App lifecycle:** Need to identify where to hook `flushSave()` — likely `AppDelegate.applicationWillTerminate(_:)` or equivalent.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None

### 5.2 Files to Modify

- `Ora/Persistence/PersistenceManager.swift` — Add `private var saveTask: Task<Void, Never>?`, modify `saveContext()` to debounce, add `func flushSave()` that cancels pending task and saves immediately
- `Ora/Ora/AppDelegate.swift` (or equivalent lifecycle hook) — Call `PersistenceManager.shared.flushSave()` on termination

### 5.3 Tests to Add

- `OraTests/PersistenceDebouncingTests.swift` — Test that rapid appends don't trigger multiple saves
- Test that `flushSave()` forces an immediate save
- Test that data survives after flush

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [x] AC-1: Rapid message appends (3+ within 500ms) trigger only one `context.save()` call
- [x] AC-2: `flushSave()` forces an immediate save regardless of debounce timer
- [x] AC-3: App termination path calls `flushSave()` to prevent data loss
- [x] AC-4: Messages appended just before termination are persisted

## 7. Verification Plan

### Automated Tests

- [x] Unit test: append 5 messages rapidly, verify save count is 1 (or fewer than 5)
- [x] Unit test: call flushSave after append, verify data is persisted immediately

### Manual Tests

- [ ] Have rapid conversation, force-quit shortly after last message — verify all messages persisted

## 8. Performance / Reliability Considerations

- Debounce window of 250–500ms balances responsiveness with save frequency
- Must not lose messages if app crashes between append and debounced save — this is an accepted risk for v1 (crash ≠ clean termination)

## 9. Risks & Mitigations

- **Risk:** App crash between append and save loses recent messages → **Mitigation:** Acceptable for v1; MEM.16 (ModelActor) can provide write-ahead logging if needed
- **Risk:** Debounce window too long delays persistence → **Mitigation:** 250ms is fast enough; flush on termination covers clean shutdown

## 10. Open Questions

- None

---

## Implementation Summary
**Date:** 2026-02-14
**Branch:** `feat/MEM.04-debounced-save-scheduler`
**Commits:** 2
**Implemented by:** codex (complexity score: 7/10)
**Reviewed by:** pi (1 iteration, approved — no issues)

### Files Changed
- `Ora/Persistence/PersistenceManager.swift` — Added debounced save via `Task<Void, Never>?` with configurable interval (default 250ms), `flushSave()` for immediate persist, `performSave()` extracted from `saveContext()`
- `Ora/AppDelegate.swift` — Added `PersistenceManager.shared.flushSave()` call in `applicationWillTerminate`
- `OraTests/PersistenceDebouncingTests.swift` — 3 tests: rapid append coalescing, flush forces immediate save, disk round-trip after flush

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-14T23:09:00Z
**Commit reviewed:** f9660fe
**Iteration:** 1

### Summary
- Files reviewed: 4
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- None

#### P1 - Major (Should fix)
- None

#### P2 - Minor (Can defer)
- None

### Future Considerations (Out of Scope)
- `PersistenceManager.swift` - Consider making `saveContext` public or providing a `save()` method if external components modify model objects directly without going through `PersistenceManager` helper methods (currently safe as helpers are used).

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
