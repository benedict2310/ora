# MEM.10 - Memory Trigger Detector

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** MEM.06
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Detect when a user's prompt likely requires memory retrieval, so that retrieval only runs when needed (precision-biased). This avoids injecting irrelevant memory context into every prompt and keeps latency low for simple queries.

## 2. User Story

As a user, I want Ora to recall relevant context from past conversations when I reference them, without slowing down simple questions.

## 3. Scope

### In Scope

- Implement `MemoryTriggerDetector` that analyzes user input for memory-dependent signals
- Trigger categories:
  - **Linguistic:** "remember", "last time", "as we discussed", "what did we decide", "my preference", "you told me", "we agreed"
  - **Entity overlap:** Names, projects, or keywords found in MEMORY.md section headers or entries
  - **Task framing:** "next steps", "did we decide", "why did we choose", "follow up on"
- Return a `MemoryTriggerResult` with confidence score and trigger type
- Configurable threshold for activation (default: trigger if any signal matches)

### Out of Scope

- Actual retrieval execution (MEM.11–MEM.13)
- LLM-based intent classification (future refinement)
- Trigger detection for tool-specific memory (e.g., "call the same person as last time")

## 4. Architecture Alignment

- **Component:** New `Ora/Memory/MemoryTriggerDetector.swift`
- **Integration point:** Called from `AgentLoop.process(userText:)` before LLM inference
- **Concurrency:** Stateless, synchronous analysis — no actor needed
- **Dependency:** Reads MEMORY.md entity index for entity overlap detection (lazy-loaded, cached)

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/MemoryTriggerDetector.swift` — Trigger detection logic

### 5.2 Files to Modify

- `Ora/Orchestration/AgentLoop.swift` — Call trigger detector before LLM call; pass result to retrieval pipeline (MEM.11)

### 5.3 Tests to Add

- `OraTests/MemoryTriggerDetectorTests.swift` — Test each trigger category with positive/negative examples

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [x] AC-1: Linguistic triggers ("remember", "last time", etc.) are detected correctly
- [x] AC-2: Entity overlap with MEMORY.md entries triggers retrieval
- [x] AC-3: Task framing keywords ("next steps", "why did we choose") trigger retrieval
- [x] AC-4: Simple questions without memory signals do NOT trigger retrieval
- [x] AC-5: Detection completes in < 5ms for typical inputs

## 7. Verification Plan

### Automated Tests

- [x] Unit test: "What did we decide about the project?" → triggers
- [x] Unit test: "What's the weather?" → does not trigger
- [x] Unit test: "Remember my preference for morning meetings" → triggers
- [x] Unit test: Entity mentioned in MEMORY.md → triggers

### Manual Tests

- [ ] Ask memory-dependent questions, verify retrieval is invoked
- [ ] Ask simple questions, verify no retrieval overhead

## 8. Performance / Reliability Considerations

- Must be fast (< 5ms) — runs on every user input before LLM call
- Entity index should be cached, not re-read from disk on every query

## 9. Risks & Mitigations

- **Risk:** False positives inject irrelevant memory → **Mitigation:** Precision-biased thresholds; only inject top-scoring results
- **Risk:** False negatives miss memory-dependent queries → **Mitigation:** Start with broad keyword list, refine with usage data

## 10. Open Questions

- None

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-15T10:37:00Z
**Commit reviewed:** 0536103
**Iteration:** 2

### Summary
- Files reviewed: 4
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [ ] None

#### P1 - Major (Should fix)
- [x] `MemoryTriggerDetector.swift:76` - `EntityIndexCache` caching issue fixed.

#### P2 - Minor (Can defer)
- [ ] `MemoryTriggerDetector.swift:207` - `loadEntityTokens` swallows file read errors. Acceptable for robustness.

### Future Considerations (Out of Scope)
- `MemoryTriggerDetector.swift` - Hardcoded stop words list is long and language-specific.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
