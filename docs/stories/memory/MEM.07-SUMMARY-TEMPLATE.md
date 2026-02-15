# MEM.07 - Summary Template

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 0.5 days
**Dependencies:** MEM.06
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Define a multi-resolution summary template for session summaries. Each session gets a summary file at `~/Documents/Ora/Memory/Summaries/<session_id>.md` with structured sections: TL;DR, bullet points, decisions & commitments, and open loops.

## 2. User Story

As a user, I want each conversation summarized in a structured format so that I can quickly review what happened without reading the full transcript.

## 3. Scope

### In Scope

- Define the summary template structure as a Swift type (`SessionSummary`)
- Template sections:
  - **TL;DR:** 1–2 sentences
  - **Bullets:** 5–12 key points
  - **Decisions & Commitments:** structured list with decision + rationale + timestamp
  - **Open Loops:** unanswered questions / follow-ups
- Implement template rendering to markdown string
- Write a placeholder summary for the active session (actual content generation is MEM.08)

### Out of Scope

- LLM-based summary generation (MEM.08)
- Memory distillation and MEMORY.md updates (MEM.09)

## 4. Architecture Alignment

- **Component:** New `Ora/Memory/SessionSummary.swift`
- **Data flow:** `SessionSummary` is a plain `Codable, Sendable` value type — no SwiftData, no actor constraints
- **File output:** Uses `MemoryFileManager` (MEM.06) for path resolution

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/SessionSummary.swift` — Summary model + markdown rendering

### 5.2 Files to Modify

- `Ora/Memory/MemoryFileManager.swift` — Add `writeSummary(sessionId:content:)` method

### 5.3 Tests to Add

- `OraTests/SessionSummaryTests.swift` — Test template rendering, markdown output format

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [x] AC-1: `SessionSummary` type captures TL;DR, bullets, decisions, and open loops
- [x] AC-2: `renderMarkdown()` produces well-formatted markdown with all sections
- [x] AC-3: Summary file can be written to `~/Documents/Ora/Memory/Summaries/<session_id>.md`
- [x] AC-4: Summary files are human-readable in any text editor

## 7. Verification Plan

### Automated Tests

- [x] Unit test: render a sample summary, verify markdown structure
- [x] Unit test: verify all sections present in output

### Manual Tests

- [ ] Write a summary file, open in text editor — verify readability

## 8. Performance / Reliability Considerations

- Summary rendering is lightweight string formatting — no performance concerns

## 9. Risks & Mitigations

- **Risk:** Template is too rigid for varied conversations → **Mitigation:** Allow empty sections; template is a starting point refined in MEM.08

## 10. Open Questions

- None

---

## Implementation Summary

- Created `Ora/Memory/SessionSummary.swift` with struct `SessionSummary` conforming to `Codable`, `Sendable`.
- Implemented markdown rendering logic with placeholder handling for empty fields.
- Updated `Ora/Memory/MemoryFileManager.swift` to support writing summary files to `~/Documents/Ora/Memory/Summaries/`.
- Added `OraTests/SessionSummaryTests.swift` to verify markdown output format.
- Added integration tests in `OraTests/MemoryFileManagerTests.swift` for file writing.

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-15T09:12:00Z
**Commit reviewed:** e16a23f
**Iteration:** 2

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
- Consider caching `DateFormatter` if summary generation becomes high frequency (currently once per session).

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
