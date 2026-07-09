# MEM.01 - Conversation Persistence Sink

**Epic:** Memory System
**Status:** Complete
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** F.08
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Conversations must survive app restart and crash. Add a minimal API in `PersistenceManager` to append messages to the active `Session` in SwiftData. Currently, `Session.addMessage(role:content:)` exists but is never called from the conversation flow — this story closes that gap by providing the persistence entry point.

## 2. User Story

As a user, I want my conversation history preserved across app restarts so that I don't lose context from previous interactions.

## 3. Scope

### In Scope

- Add `appendMessage(role:content:metadata:)` method to `PersistenceManager` that loads/creates the active session and appends a `Session.Message`
- Confirm/extend `Session.addMessage(role:content:)` to include UUID + timestamp on every message
- Ensure `Session.updatedAt` is updated when messages are appended
- Validate that the SwiftData store is non-empty after at least one message

### Out of Scope

- Wiring persistence into AgentLoop (MEM.02)
- Tool result persistence (MEM.03)
- Debounced saves (MEM.04)
- Background persistence / ModelActor (MEM.16)

## 4. Architecture Alignment

- **Component:** `Ora/Persistence/PersistenceManager.swift`, `Ora/Persistence/Models/Session.swift`
- **Concurrency:** `PersistenceManager` is `@MainActor` — `appendMessage` will also be `@MainActor`, matching the current design. Heavy encoding is acceptable for now (addressed in MEM.04/MEM.16).
- **SwiftData constraint:** `ModelContext` and `@Model` instances are not `Sendable` — all operations stay on the main actor in this story.
- **Current state:** `Session.addMessage(role:content:)` exists and encodes to `messagesData` JSON blob. `PersistenceManager.currentSession()` fetches or creates the active session (`isComplete == false`). `saveContext()` is called after every mutation (private method).

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None

### 5.2 Files to Modify

- `Ora/Persistence/PersistenceManager.swift` — Add public `appendMessage(role:content:timestamp:)` that calls `currentSession().addMessage(...)` then `saveContext()`
- `Ora/Persistence/Models/Session.swift` — Verify `addMessage` sets UUID + timestamp; ensure `updatedAt` is updated on append

### 5.3 Tests to Add

- `OraTests/PersistenceManagerTests.swift` — Test `appendMessage` creates a session if none exists, appends message, and persists to store
- Test that `Session.updatedAt` changes after `appendMessage`
- Test that multiple appends accumulate correctly

### 5.4 Dependencies/Config

- None (uses existing SwiftData schema)

## 6. Acceptance Criteria

- [ ] AC-1: Calling `PersistenceManager.appendMessage(role:content:)` creates/loads the active `Session` and appends a `Session.Message` with UUID + timestamp
- [ ] AC-2: `Session.updatedAt` changes when messages are appended
- [ ] AC-3: SwiftData store (`.default.store`) is non-empty after at least one message
- [ ] AC-4: Multiple sequential appends accumulate correctly in `session.messages`

## 7. Verification Plan

### Automated Tests

- [ ] Unit test: append message to fresh session, verify message count and content
- [ ] Unit test: append multiple messages, verify ordering and uniqueness
- [ ] Unit test: verify `updatedAt` changes on append

### Manual Tests

- [ ] Launch app, trigger a conversation, force quit, relaunch — verify messages are in the session

## 8. Performance / Reliability Considerations

- Each `appendMessage` currently triggers `saveContext()` immediately — this is acceptable for v1 but will be optimized in MEM.04 (debounced saves)
- JSON encode/decode of `messagesData` blob runs on main actor — acceptable for short conversations, tracked in MEM.05

## 9. Risks & Mitigations

- **Risk:** Frequent saves block main actor during rapid exchanges → **Mitigation:** MEM.04 adds debouncing; keep this story simple
- **Risk:** `messagesData` blob grows large over many messages → **Mitigation:** MEM.17 (future) migrates to relationship model if needed

## 10. Open Questions

- None

---

## Implementation Summary

**Date:** 2026-02-14
**Branch:** `feat/MEM.01-conversation-persistence-sink`
**Commits:** 3
**Implemented by:** codex (complexity score: 7/10)
**Reviewed by:** pi (2 iterations)

### Files Changed
- `Ora/Persistence/PersistenceManager.swift` — Added `appendMessage(role:content:metadata:)` method; enhanced `createForTesting` with `storeURL` parameter
- `Ora/Persistence/Models/Session.swift` — Added `metadata` field to `Message`; added `timestamp` parameter to `addMessage`
- `OraTests/PersistenceTests.swift` — Added 4 new tests covering append, updatedAt, accumulation, and disk persistence

## Code Review Findings

**Reviewer:** pi (Codex Subagent)
**Date:** 2026-02-14T19:58:46+01:00
**Commit reviewed:** a4bc0fd
**Iteration:** 2

### Summary
- Files reviewed: 3
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- None

#### P1 - Major (Should fix)
- None (iteration 1 finding — metadata not persisted — fixed in commit a4bc0fd)

#### P2 - Minor (Can defer)
- None

### Future Considerations (Out of Scope)
- `Ora/Persistence/Models/Session.swift` - The `messages` setter silently swallows encoding errors and sets `messagesData` to nil. This is pre-existing behavior but worth addressing in a future reliability story (e.g., MEM.04 or MEM.05).

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
