# MEM.06 - On-Disk Memory Folder

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 0.5 days
**Dependencies:** MEM.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Establish a user-visible folder structure for long-term memory artifacts: `~/Documents/Ora/Memory/MEMORY.md` and `~/Documents/Ora/Memory/Summaries/<session_id>.md`. These files are human-editable and inspectable, giving users full transparency into what Ora remembers.

## 2. User Story

As a user, I want Ora's memory stored in a folder I can browse and edit so that I have full control over what Ora remembers about me.

## 3. Scope

### In Scope

- Create `~/Documents/Ora/Memory/` directory structure on first run
- Create `~/Documents/Ora/Memory/MEMORY.md` with initial template if missing
- Create `~/Documents/Ora/Memory/Summaries/` directory
- Provide a `MemoryFileManager` utility for path resolution and directory creation
- Ensure files are created if missing (idempotent)

### Out of Scope

- Writing actual content to MEMORY.md (MEM.08, MEM.09)
- Writing session summaries (MEM.07, MEM.08)
- File watching for edits (MEM.14)
- In-app UI for memory management (MEM.15)

## 4. Architecture Alignment

- **Component:** New `Ora/Memory/MemoryFileManager.swift`
- **Storage location:** `~/Documents/Ora/Memory/` — user-visible per Apple guidelines for user-editable artifacts (not Application Support, which is for app-managed data)
- **Concurrency:** File operations can be synchronous on first-run or async during normal operation
- **No SwiftData involvement:** These are plain markdown files on disk

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/MemoryFileManager.swift` — Path resolution, directory creation, template creation

### 5.2 Files to Modify

- `Ora/Ora/AppDelegate.swift` (or app initialization) — Call `MemoryFileManager.ensureDirectories()` on launch
- `project.yml` — Add `Memory` folder to source groups if needed

### 5.3 Tests to Add

- `OraTests/MemoryFileManagerTests.swift` — Test directory creation, template creation, idempotency

### 5.4 Dependencies/Config

- None (uses `FileManager.default`)

## 6. Acceptance Criteria

- [x] AC-1: `~/Documents/Ora/Memory/` directory exists after first run
- [x] AC-2: `~/Documents/Ora/Memory/MEMORY.md` exists with initial template content
- [x] AC-3: `~/Documents/Ora/Memory/Summaries/` directory exists after first run
- [x] AC-4: User can open and edit `MEMORY.md` with any text editor
- [x] AC-5: Subsequent launches don't overwrite existing MEMORY.md content

## 7. Verification Plan

### Automated Tests

- [x] Unit test: create directories in temp location, verify structure
- [x] Unit test: verify idempotency (call twice, second call doesn't overwrite)

### Manual Tests

- [ ] Launch app, open `~/Documents/Ora/Memory/` in Finder — verify structure exists
- [ ] Edit MEMORY.md, relaunch — verify edits survive

## 8. Performance / Reliability Considerations

- Directory creation is fast and only happens once
- Must handle case where user deletes the folder (recreate on next launch)

## 9. Risks & Mitigations

- **Risk:** User doesn't have Documents folder access → **Mitigation:** Handle permission errors gracefully, log warning
- **Risk:** Sandboxing restricts access to ~/Documents → **Mitigation:** Ora is not sandboxed (Developer ID signed); verify in entitlements

## 10. Open Questions

- None

---

## Implementation Summary
**Date:** 2026-02-15
**Branch:** `feat/MEM.06-on-disk-memory-folder`
**Commits:** 1
**Implemented by:** codex (complexity score: 7/10)
**Reviewed by:** pi (1 iteration, approved — no issues)

### Files Changed
- `Ora/Memory/MemoryFileManager.swift` — New: path resolution, directory creation, MEMORY.md template bootstrap, idempotent `ensureDirectories()`
- `Ora/AppDelegate.swift` — Call `MemoryFileManager.shared.ensureDirectories()` on launch
- `OraTests/MemoryFileManagerTests.swift` — Tests: directory creation, template content, idempotency

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-15T08:35:00Z
**Commit reviewed:** c1b9a6f
**Iteration:** 1

### Summary
- Files reviewed: 3
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
None.

#### P1 - Major (Should fix)
None.

#### P2 - Minor (Can defer)
None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
