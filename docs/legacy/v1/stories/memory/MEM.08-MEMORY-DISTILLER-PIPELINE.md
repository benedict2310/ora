# MEM.08 - Memory Distiller Pipeline

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 2-3 days
**Dependencies:** MEM.01, MEM.06, MEM.07
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Create an automated pipeline that runs after each session (or every N turns) to extract facts, preferences, and decisions from the conversation and produce: (1) a session summary file and (2) append-only updates to `MEMORY.md`. Uses the local LLM for distillation.

## 2. User Story

As a user, I want Ora to automatically remember important facts, preferences, and decisions from our conversations so that I don't have to repeat myself.

## 3. Scope

### In Scope

- Create `MemoryDistiller` service with `distill(sessionId:)` method
- Input: `[Session.Message]` from SwiftData (passed as plain value types, NOT SwiftData model objects)
- Output: `SessionSummary` (MEM.07) + MEMORY.md append entries
- Use LLM inference to extract structured information from transcript
- Write summary to `~/Documents/Ora/Memory/Summaries/<session_id>.md`
- Append new entries to `MEMORY.md`
- Trigger automatically when a session completes (on `completeSession()`)

### Out of Scope

- MEMORY.md deduplication and cleanup (MEM.09)
- Retrieval and indexing (MEM.10–MEM.13)
- Custom distillation prompts (future)

## 4. Architecture Alignment

- **Component:** New `Ora/Memory/MemoryDistiller.swift`
- **Concurrency:** Read `Session.messages` on MainActor (SwiftData), copy to plain `[Session.Message]` value array, then run distillation in background task. **Never pass SwiftData models across actor boundaries.**
- **LLM usage:** Uses `LLMService` for inference with a distillation-specific system prompt. Must respect GPU memory (clear cache after distillation per CLAUDE.md guidelines).
- **Trigger point:** `PersistenceManager.completeSession()` or `AgentLoop.endSession()`

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/MemoryDistiller.swift` — Core distillation service
- `Ora/Resources/memory-distill-prompt.txt` — System prompt for distillation (extraction instructions)

### 5.2 Files to Modify

- `Ora/Orchestration/AgentLoop.swift` — Trigger distillation on session end
- `Ora/Memory/MemoryFileManager.swift` — Add `appendToMemory(entries:)` method

### 5.3 Tests to Add

- `OraTests/MemoryDistillerTests.swift` — Test extraction from sample transcripts
- Test that distillation produces valid SessionSummary
- Test that MEMORY.md append doesn't corrupt existing content

### 5.4 Dependencies/Config

- None (uses existing LLM infrastructure)

## 6. Acceptance Criteria

- [x] AC-1: `MemoryDistiller.distill(sessionId:)` produces a `SessionSummary` from a persisted transcript
- [x] AC-2: Summary file is written to `~/Documents/Ora/Memory/Summaries/<session_id>.md`
- [x] AC-3: New memory entries are appended to `MEMORY.md` without overwriting existing content
- [x] AC-4: Distillation runs automatically when a session completes
- [x] AC-5: SwiftData models are NOT passed across actor boundaries (only plain value types)
- [x] AC-6: GPU cache is cleared after distillation completes

## 7. Verification Plan

### Automated Tests

- [x] Unit test: mock transcript → distill → verify summary structure
- [x] Unit test: verify MEMORY.md append preserves existing content
- [x] Unit test: verify distillation with empty transcript produces no entries

### Manual Tests

- [ ] Have a conversation mentioning preferences ("I prefer morning meetings"), end session — verify MEMORY.md contains extracted preference
- [ ] Check summary file is generated with correct structure

## 8. Performance / Reliability Considerations

- Distillation uses LLM inference — can take seconds. Must run in background, not block next conversation.
- Clear GPU cache after distillation per CLAUDE.md guidelines (`GPU.clearCache()`)
- If distillation fails (LLM error), log warning but don't corrupt existing files

## 9. Risks & Mitigations

- **Risk:** LLM produces malformed output → **Mitigation:** Use structured output validation (existing `JSONValidator` pattern); fallback to no-op
- **Risk:** Distillation takes too long, delays next conversation → **Mitigation:** Run in detached background task; user can start new session immediately
- **Risk:** Memory entries extracted inaccurately → **Mitigation:** Users can edit MEMORY.md (it's just a markdown file); improve prompts over time

## 10. Open Questions

- Should distillation run on every session end, or only for sessions above a minimum turn count (e.g., 3+ turns)?
- Should there be a cooldown between distillation runs to avoid excessive GPU usage?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-15T09:40:00Z
**Commit reviewed:** c8d1a73
**Iteration:** 1

### Summary
- Files reviewed: 8
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [x] None

#### P1 - Major (Should fix)
- [x] None

#### P2 - Minor (Can defer)
- [ ] `MemoryDistiller.swift:161` - `replacingOccurrences(of: "\\s+", ...)` collapses all whitespace. This might affect readability of code blocks if the user pasted code, but is acceptable for memory distillation purposes.

### Future Considerations (Out of Scope)
- Consider adding a cooldown or debounce mechanism if users create many short sessions rapidly to avoid queuing up many distillation tasks.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
