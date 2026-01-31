# BG.05 - Summary Generation

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1–2 days
**Dependencies:** BG.02, BG.04
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Generate concise, safe summaries for completed background research tasks and persist them alongside artifacts for later retrieval.

## 2. User Story

As a user, I want Ora to summarize completed research tasks so I can quickly review outcomes without reading raw sources.

## 3. Scope

### In Scope

- Summary generation pipeline (LLM-based) for completed tasks
- Safe prompt template that avoids prompt injection
- Summary persistence in artifact folder
- Background-task summary notifications (via BG.06)

### Out of Scope

- Real-time streaming summaries
- Multi-document semantic merging beyond the summary prompt
- Cross-device sync

## 4. Architecture Alignment

- **Component:** `BackgroundTaskManager` (actor) + `SummaryGenerator`
- **LLM Access:** Must be serialized via `MLXMetalGate`
- **Storage:** `ArtifactStore` writes `summary.md`

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/BackgroundTasks/SummaryGenerator.swift`
- `Ora/BackgroundTasks/SummaryPrompt.swift`

### 5.2 Files to Modify

- `Ora/BackgroundTasks/BackgroundTaskManager.swift`
- `Ora/BackgroundTasks/ArtifactStore.swift`

### 5.3 Tests to Add

- `OraTests/BackgroundTasks/SummaryGeneratorTests.swift`

## 6. Acceptance Criteria

- [ ] AC-1: Summary generation is queued after task completion.
- [ ] AC-2: Summary is written to `summary.md` in the artifact folder.
- [ ] AC-3: Summary prompt explicitly blocks prompt injection.
- [ ] AC-4: Summary generation does not interrupt active conversation generation.

## 7. Verification Plan

### Automated Tests

- Verify `SummaryGenerator` writes a summary file.
- Verify prompt template includes injection guardrails.

### Manual Tests

- Trigger a background research task and confirm `summary.md` is created.

## 8. Performance / Reliability Considerations

- Summary generation must respect GPU serialization and should not delay foreground responses.
- Timeouts should be enforced to avoid hanging background tasks.

## 9. Risks & Mitigations

- **Risk:** Prompt injection from fetched content. **Mitigation:** Summarize only sanitized input; include explicit system constraints.
- **Risk:** LLM contention with conversation. **Mitigation:** Use `MLXMetalGate` and defer to active user sessions.

## 10. Open Questions

- How large should the summary be (word limit)?
- Should we store a short + long summary?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
