# MEM.03 - Tool Result Persistence

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** MEM.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Persist tool result artifacts into the conversation transcript without bloating `messagesData`. Tool results should appear in the persisted session as `.tool` role messages with a short summary and link to the existing audit log entry.

## 2. User Story

As a user, I want tool execution results preserved in my conversation history so that I can see what actions Ora took and their outcomes.

## 3. Scope

### In Scope

- Persist tool results as `Session.Message` with role `.tool`
- Keep persisted content bounded: short summary + audit log reference (not full tool output)
- Format: `[ToolResult: <toolName>] <short summary> (auditId=<uuid>)`
- Wire persistence into AgentLoop tool execution flow (lines ~251, 386, 395 where `conversationManager.addToolResult()` is called)

### Out of Scope

- Changing how `AuditLogEntryModel` stores full tool output (already working)
- Modifying audit log display in Preferences
- Changing ConversationManager's in-memory handling of tool results

## 4. Architecture Alignment

- **Components:** `Ora/Orchestration/AgentLoop.swift`, `Ora/Persistence/AuditLogger.swift`
- **Audit log linkage:** `AuditLogEntryModel` already stores `sessionID`, full `parametersData`, and `result`. Tool persistence in the transcript only needs to reference this via `auditId`.
- **Current flow:** `AuditLogger.recordToolCall()` creates the audit entry → tool executes → `AuditLogger.recordSuccess/recordFailure()` updates it. The audit entry ID is available at each step.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None

### 5.2 Files to Modify

- `Ora/Orchestration/AgentLoop.swift` — After tool execution, persist a `.tool` role message with bounded summary referencing the audit log entry ID
- `Ora/Persistence/Models/Session.swift` — Ensure `.tool` is a valid `Message.Role` case (verify it exists)

### 5.3 Tests to Add

- `OraTests/ToolResultPersistenceTests.swift` — Test that tool results appear in persisted session messages with `.tool` role
- Test that persisted content is bounded (not full tool output)
- Test that audit log ID is included in the persisted message

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [x] AC-1: Tool results appear in persisted `Session.messages` with role `.tool`
- [x] AC-2: Persisted tool message content includes tool name and short summary
- [x] AC-3: Persisted tool message references the audit log entry ID
- [x] AC-4: Transcript does not grow unbounded due to large tool outputs (full output stays in audit log only)

## 7. Verification Plan

### Automated Tests

- [x] Unit test: execute a tool, verify `.tool` message in session with bounded content
- [x] Unit test: verify audit ID reference is parseable from persisted message

### Manual Tests

- [ ] Trigger calendar query, quit and relaunch — verify tool result appears in session transcript

## 8. Performance / Reliability Considerations

- Tool result summaries should be capped (e.g., 500 chars max) to prevent blob growth
- Full tool output remains available via audit log for detailed inspection

## 9. Risks & Mitigations

- **Risk:** Summary truncation loses important context → **Mitigation:** Keep audit log linkage so full details are always recoverable
- **Risk:** Tool name changes break parsing → **Mitigation:** Use structured format with clear delimiters

## 10. Open Questions

- None

---

## Implementation Summary
**Date:** 2026-02-14
**Branch:** `feat/MEM.03-tool-result-persistence`
**Commits:** 2
**Implemented by:** codex (complexity score: 6/10)
**Reviewed by:** pi (1 iteration, approved)

### Files Changed
- `Ora/Tools/ToolHost.swift` — Added `ToolExecutionRecord` and `ToolExecutionError` types; new `executeWithAudit()` method that returns audit entry ID alongside tool result
- `Ora/Orchestration/AgentLoop.swift` — Added `persistToolResultMessage()` and `boundedToolSummary()` helpers; wired persistence into all 3 tool execution sites (confirmed, auto-read, failure)
- `OraTests/ToolResultPersistenceTests.swift` — New test file: success persistence with role/format/auditID verification, bounded summary truncation test

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-14T22:45:00Z
**Commit reviewed:** a6df975
**Iteration:** 1

### Summary
- Files reviewed: 4
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [ ] None

#### P1 - Major (Should fix)
- [ ] None

#### P2 - Minor (Can defer)
- [ ] `Ora/Tools/ToolHost.swift` (105-120) - Unnecessary double JSON serialization to cross actor boundary. Pass `args` (Sendable) directly to `MainActor.run` and convert to `[String: Any]` inside the closure.
- [ ] `Ora/Orchestration/AgentLoop.swift:513` - `boundedToolSummary` applies regex replacement on potentially large strings before truncation. Consider truncating to a safe limit (e.g. 2x max length) before regex to avoid performance impact on massive tool outputs.
- [ ] `OraTests/ToolResultPersistenceTests.swift` - Missing test case for tool execution failure. Ensure that `ToolExecutionError` correctly triggers the persistence flow with audit ID.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
