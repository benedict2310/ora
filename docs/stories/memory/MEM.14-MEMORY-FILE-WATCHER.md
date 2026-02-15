# MEM.14 - MEMORY.md File Watcher

**Epic:** Memory System
**Status:** Not Started
**Priority:** P2 (Medium)
**Estimated Effort:** 1 day
**Dependencies:** MEM.06, MEM.11
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Watch `MEMORY.md` for user edits and automatically re-index the retrieval index so that Ora immediately respects changes. This closes the loop on user editability: users can add, modify, or delete memory entries and Ora adapts.

## 2. User Story

As a user, I want my edits to MEMORY.md to take effect immediately so that I can correct or update what Ora remembers.

## 3. Scope

### In Scope

- Monitor `~/Documents/Ora/Memory/MEMORY.md` for file changes
- Use `DispatchSource.makeFileSystemObjectSource` (or `FileMonitor` pattern) for efficient watching
- On change detected: re-parse MEMORY.md and update the retrieval index (MEM.11)
- Debounce file change notifications (user may be typing/saving repeatedly)

### Out of Scope

- Watching summary files for changes (summaries are Ora-generated, not user-edited)
- Conflict resolution between Ora writes and user edits (serialize through MemoryFileManager)
- In-app editing UI (MEM.15)

## 4. Architecture Alignment

- **Component:** `Ora/Memory/MemoryFileManager.swift` or new `Ora/Memory/MemoryFileWatcher.swift`
- **Concurrency:** File system events arrive on a dispatch queue; index update is dispatched to the index actor
- **Lifecycle:** Start watching on app launch, stop on termination

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/MemoryFileWatcher.swift` — File system monitoring with debounce

### 5.2 Files to Modify

- `Ora/Memory/MemoryIndex.swift` — Add `reindexMemoryFile()` method
- App initialization — Start file watcher on launch

### 5.3 Tests to Add

- `OraTests/MemoryFileWatcherTests.swift` — Test change detection and debouncing

### 5.4 Dependencies/Config

- None (uses system `DispatchSource`)

## 6. Acceptance Criteria

- [ ] AC-1: Editing MEMORY.md in an external editor triggers re-indexing
- [ ] AC-2: Re-indexing completes within 1 second of file save
- [ ] AC-3: Rapid saves (typing) are debounced into a single re-index
- [ ] AC-4: Deleted entries in MEMORY.md are removed from the retrieval index

## 7. Verification Plan

### Automated Tests

- [ ] Unit test: write to watched file, verify callback fires
- [ ] Unit test: rapid writes trigger only one callback (debounce)

### Manual Tests

- [ ] Edit MEMORY.md, immediately ask Ora about the change — verify it's reflected

## 8. Performance / Reliability Considerations

- File watching is lightweight (kernel-level notification)
- Debounce window of 500ms–1s prevents thrashing during active editing

## 9. Risks & Mitigations

- **Risk:** File descriptor leak if watcher not properly cleaned up → **Mitigation:** Cancel source on deinit/termination
- **Risk:** Race between Ora writing and user editing → **Mitigation:** MemoryFileManager serializes all writes; watcher ignores Ora's own writes (use a write-in-progress flag)

## 10. Open Questions

- None

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
