# MEM.02 - AgentLoop Persistence Integration

**Epic:** Memory System
**Status:** Complete
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1 day
**Dependencies:** MEM.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Wire persistence into the conversation orchestration flow so that user and assistant messages are written to SwiftData whenever they pass through `AgentLoop`. This ensures crash-safety: if the model call fails, the user message is still persisted.

## 2. User Story

As a user, I want every message I send and every response Ora gives to be saved automatically so that I never lose conversation history.

## 3. Scope

### In Scope

- Persist user message **before** LLM call begins (crash-safety)
- Persist assistant message **after** LLM generation completes
- Wire persistence calls in `AgentLoop.process(userText:)` flow
- Ensure ordering: persist → add to ConversationManager → proceed

### Out of Scope

- Tool result persistence (MEM.03)
- Modifying ConversationManager's in-memory trimming behavior
- Session restore on app relaunch (loading persisted messages back into ConversationManager)

## 4. Architecture Alignment

- **Component:** `Ora/Orchestration/AgentLoop.swift`
- **Concurrency:** `AgentLoop` is an `actor` (not `@MainActor`). `PersistenceManager.appendMessage()` is `@MainActor`. Calls from AgentLoop will use `await` to cross the actor boundary.
- **Pipeline boundaries preserved:** Persistence is a side-effect, not part of the LLM/tool pipeline. AgentLoop remains the orchestrator.
- **Current flow in `process(userText:)`:**
  1. `conversationManager.addUserMessage(userText)` (line ~207)
  2. LLM call + tool loop
  3. `conversationManager.addAssistantMessage(text)` (lines ~288, 294, 352)

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None

### 5.2 Files to Modify

- `Ora/Orchestration/AgentLoop.swift` — Add `await PersistenceManager.shared.appendMessage(role: .user, content: userText)` before `conversationManager.addUserMessage(...)`. Add `await PersistenceManager.shared.appendMessage(role: .assistant, content: text)` after assistant message is finalized.

### 5.3 Tests to Add

- `OraTests/AgentLoopPersistenceTests.swift` — Test that user message is persisted even when LLM call throws
- Test that assistant message is persisted after successful generation
- Test message ordering matches conversation flow

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [ ] AC-1: User message is persisted to SwiftData **before** LLM inference begins
- [ ] AC-2: Assistant message is persisted to SwiftData after generation completes
- [ ] AC-3: Restarting the app retains the full transcript of the last session (user + assistant messages)
- [ ] AC-4: If the model call fails or throws, the user message is still persisted

## 7. Verification Plan

### Automated Tests

- [ ] Unit test: mock LLM failure, verify user message persisted
- [ ] Unit test: successful flow, verify both user and assistant messages persisted in order

### Manual Tests

- [ ] Start conversation, force-quit mid-response, relaunch — verify user message survives
- [ ] Complete multi-turn conversation, quit normally, relaunch — verify full transcript

## 8. Performance / Reliability Considerations

- `await` call to MainActor persistence from AgentLoop actor introduces a hop — acceptable latency for persistence
- No retry logic needed — if persistence fails, log error but don't block the conversation

## 9. Risks & Mitigations

- **Risk:** MainActor hop adds latency before LLM call → **Mitigation:** Persistence is fast (single JSON encode + save); MEM.04 adds debouncing
- **Risk:** Race between persist and ConversationManager add → **Mitigation:** Sequential await ensures ordering

## 10. Open Questions

- None

---

## Implementation Summary
**Date:** 2026-02-14
**Branch:** `feat/MEM.02-agentloop-persistence`
**Commits:** 2
**Implemented by:** codex (complexity score: 7/10)
**Reviewed by:** pi (1 iteration)

### Files Changed
- `Ora/Orchestration/AgentLoop.swift` — Added `AgentLoopPersistenceSink` protocol, `SwiftDataAgentLoopPersistenceSink` bridge, injectable `persistenceSink` dependency, and `persistMessage()` helper. User message persisted before LLM call; assistant message persisted after generation in both `runLoop()` and `generateFollowUp()`.
- `OraTests/Orchestration/AgentLoopPersistenceTests.swift` — Created. Tests ordering (user persist before LLM), crash-safety (user persisted when LLM fails), and full flow (both user + assistant persisted in order).

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-14T21:05:00Z
**Commit reviewed:** 18d45a5
**Iteration:** 1

### Summary
- Files reviewed: 2
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [ ] None

#### P1 - Major (Should fix)
- [ ] None

#### P2 - Minor (Can defer)
- [ ] `AgentLoop.swift:22` - `SwiftDataAgentLoopPersistenceSink` struct is defined in `AgentLoop.swift` (top level) rather than a separate file. While this keeps file count down, it adds clutter. Consider moving to `Persistence/` or making private if possible. (Acceptable for this story given "Files to Create: None" constraint).

### Future Considerations (Out of Scope)
- `AgentLoop.swift` - Proposals (tool confirmations) are currently not persisted or added to conversation history. Ensure this is aligned with future conversation history requirements.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
