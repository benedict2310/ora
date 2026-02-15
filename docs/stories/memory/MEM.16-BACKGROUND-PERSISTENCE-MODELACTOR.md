# MEM.16 - Background Persistence ModelActor

**Epic:** Memory System
**Status:** Not Started
**Priority:** P3 (Low / Future)
**Estimated Effort:** 2 days
**Dependencies:** MEM.04
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Migrate heavy persistence operations (JSON encode/decode, bulk saves) off the main actor to a dedicated `ModelActor` for improved UI responsiveness. This is a hardening story — only needed if MEM.05 performance instrumentation shows main-actor blocking is a real problem.

## 2. User Story

As a user, I want Ora's UI to remain completely smooth even during heavy persistence operations.

## 3. Scope

### In Scope

- Create a dedicated `@ModelActor` that owns its own `ModelContext`
- Move JSON encode/decode of `messagesData` and `context.save()` off the main actor
- Ensure `@Model` instances and `ModelContext` are **never** passed across actor boundaries
- Pass only plain value types (`Session.Message` structs) between actors

### Out of Scope

- Migrating from blob storage to relationships (MEM.17)
- Changing the SwiftData schema

## 4. Architecture Alignment

- **Component:** `Ora/Persistence/PersistenceManager.swift`, new `Ora/Persistence/BackgroundPersistenceActor.swift`
- **SwiftData concurrency:** Per Apple docs, `ModelContext` and `@Model` instances are not `Sendable`. The `ModelActor` macro creates a context on its own serial executor.
- **Pattern:** Main actor reads remain on `PersistenceManager`; writes are dispatched to the background actor.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Persistence/BackgroundPersistenceActor.swift` — `@ModelActor` with its own context

### 5.2 Files to Modify

- `Ora/Persistence/PersistenceManager.swift` — Delegate write operations to background actor

### 5.3 Tests to Add

- `OraTests/BackgroundPersistenceTests.swift` — Test concurrent writes, verify data consistency

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [ ] AC-1: `appendMessage` no longer blocks the main actor for JSON encoding
- [ ] AC-2: `context.save()` runs on a background actor
- [ ] AC-3: No `@Model` or `ModelContext` instances cross actor boundaries
- [ ] AC-4: Data remains consistent after concurrent read/write operations

## 7. Verification Plan

### Automated Tests

- [ ] Unit test: concurrent appends don't cause data corruption
- [ ] Unit test: main thread is not blocked during persistence (measure with XCTMetric)

### Manual Tests

- [ ] Rapid conversation during heavy persistence — verify UI remains smooth

## 8. Performance / Reliability Considerations

- Must handle ModelContainer merge conflicts between main context and background context
- Background context changes should be auto-merged to main context for UI updates

## 9. Risks & Mitigations

- **Risk:** Merge conflicts between contexts → **Mitigation:** Use `ModelContext.automaticallyMergesChangesFromParent = true`
- **Risk:** Complexity increase → **Mitigation:** Only implement if MEM.05 shows it's needed

## 10. Open Questions

- Is the `@ModelActor` macro mature enough in macOS 26 for production use?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
