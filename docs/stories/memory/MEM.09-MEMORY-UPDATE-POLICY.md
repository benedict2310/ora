# MEM.09 - Memory Update Policy

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 1 day
**Dependencies:** MEM.08
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Define a stable, user-friendly format for MEMORY.md entries and an append-only update policy that respects user edits. Memory entries should be categorized, tagged, and traceable to source sessions.

## 2. User Story

As a user, I want MEMORY.md organized into clear sections so that I can easily find, edit, and delete specific memories.

## 3. Scope

### In Scope

- Define MEMORY.md section structure:
  - `## Profile` — user identity, demographics
  - `## Preferences` — stated likes/dislikes, workflow preferences
  - `## People` — mentioned contacts, relationships
  - `## Projects` — active projects, goals
  - `## Ongoing Goals` — recurring objectives
- Define entry format: `- [fact] ... (source: <session_id> @ <timestamp>)`
- Tag types: `[fact]`, `[preference]`, `[fact][sensitive]`
- Implement append-only write policy: new entries appended under correct section without rewriting existing content
- Basic deduplication by normalized key (e.g., `pref:food:spicy`) when extractable; otherwise allow duplicates

### Out of Scope

- Automated cleanup/pruning of old entries (future story)
- Semantic deduplication using embeddings
- MEMORY.md re-indexing on edit (MEM.14)

## 4. Architecture Alignment

- **Component:** `Ora/Memory/MemoryFileManager.swift`, `Ora/Memory/MemoryDistiller.swift`
- **File format:** Plain markdown — no structured database, users edit directly
- **Concurrency:** File writes are serialized through `MemoryFileManager` to avoid corruption from concurrent distillation runs

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/MemoryEntry.swift` — Entry model with tag, content, source session ID, timestamp

### 5.2 Files to Modify

- `Ora/Memory/MemoryFileManager.swift` — Add `appendEntries(entries:)` that inserts entries under the correct MEMORY.md section
- `Ora/Memory/MemoryDistiller.swift` — Output `[MemoryEntry]` tagged with section and type

### 5.3 Tests to Add

- `OraTests/MemoryUpdatePolicyTests.swift` — Test section insertion, deduplication, user edit preservation

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [x] AC-1: MEMORY.md has defined sections (Profile, Preferences, People, Projects, Ongoing Goals)
- [x] AC-2: New entries are appended under the correct section without overwriting existing content
- [x] AC-3: Entries include source session ID and timestamp
- [x] AC-4: Entries are tagged with type (`[fact]`, `[preference]`, etc.)
- [x] AC-5: User edits to MEMORY.md persist and are not overwritten by subsequent appends
- [x] AC-6: Basic deduplication prevents identical entries from being added twice

## 7. Verification Plan

### Automated Tests

- [x] Unit test: append entries to MEMORY.md with existing content, verify structure preserved
- [x] Unit test: add duplicate entry, verify deduplication
- [x] Unit test: user-added custom lines survive append operation

### Manual Tests

- [ ] Add a custom line to MEMORY.md, trigger distillation — verify custom line survives

## 8. Performance / Reliability Considerations

- MEMORY.md file reads are fast for typical sizes (< 100KB)
- Section-based append avoids full file rewrite

## 9. Risks & Mitigations

- **Risk:** User edits break section parsing → **Mitigation:** Robust section detection; if section not found, append at end
- **Risk:** Deduplication misses semantic duplicates → **Mitigation:** Acceptable for v1; future embedding-based dedup can clean up

## 10. Open Questions

- Should sensitive entries (`[fact][sensitive]`) be stored separately or encrypted?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-15T10:05:00Z
**Commit reviewed:** e31645b
**Iteration:** 1

### Summary
- Files reviewed: 7
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [ ] None

#### P1 - Major (Should fix)
- [ ] None

#### P2 - Minor (Can defer)
- [ ] None

### Future Considerations (Out of Scope)
- `MemoryFileManager.swift`: `ensureRequiredSections` appends missing sections to the end of the file. If a user mangles a section header (e.g. `## People ` with a trailing space), the system will append a new `## People` section at the end. This is safe but might result in duplicate-looking headers if the user isn't careful.
- `MemoryEntry.Section`: Order is fixed. If the user reorders sections in the file, `appendEntries` might insert new sections out of the user's preferred order (it follows `allCases` order for missing sections). Existing sections are respected where they are found.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
