# BG.04 - Artifact Persistence

**Epic:** Background Tasks
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 1.5 days
**Dependencies:** BG.01
**Target:** macOS 26 (Tahoe)
**Design Reference:** BG.00

---

## 1. Objective

Store background task results in a user-visible, deterministic folder layout under `~/Documents/Ora Research/`. Provide APIs for saving, reading, listing, and cleaning up artifacts.

## 2. User Story

As a **user**, I want research results **saved to a visible folder on my Mac** so that I can **browse, share, and reference them outside of Ora**.

## 3. Scope

### In Scope

- `ArtifactStore` actor for managing artifact lifecycle
- Folder creation with date-based grouping and stable task ID + slug naming
- Write `result.json` (structured extraction data)
- Write `citations.json` (source URLs, titles, fetch timestamps)
- Optional `raw/` subdirectory for original fetched content
- Read artifacts back by task ID
- List all artifacts (for UI browsing and context loading)
- Auto-cleanup policy: delete artifacts older than N days (default: 30, configurable)
- Finder integration: reveal artifact folder via `NSWorkspace`
- Sandbox-compatible directory access (security-scoped bookmarks if needed)

### Out of Scope

- `summary.md` generation (BG.05)
- Cloud sync / backup
- Full-text search across artifacts
- Artifact encryption

## 4. Architecture Alignment

### Component Placement

```
Ora/BackgroundTasks/
  ├── Artifacts/
  │   ├── ArtifactStore.swift           // Actor: save, read, list, cleanup
  │   ├── ArtifactLayout.swift          // Path construction logic
  │   └── ArtifactCleaner.swift         // Scheduled cleanup
  └── ... (existing from BG.01)
```

### Folder Layout

```
~/Documents/Ora Research/
  └── 2026-01-31/
      └── task-a1b2c3-swift-concurrency/
          ├── result.json               // WorkerResult serialized
          ├── citations.json            // [{url, title, fetchedAt}]
          ├── summary.md                // Written by BG.05 (later)
          └── raw/                      // Optional
              ├── page-0.html           // Original fetched HTML
              └── page-1.html
```

### Naming Convention

- Date folder: `YYYY-MM-DD` (local timezone)
- Task folder: `task-<shortid>-<slug>`
  - `shortid`: first 6 characters of task UUID (lowercase hex)
  - `slug`: sanitized query/title, max 40 chars, lowercase, hyphens only

### File Formats

**result.json:**
```json
{
  "taskId": "uuid",
  "completedAt": "ISO8601",
  "pages": [
    {
      "url": "https://...",
      "title": "Page Title",
      "text": "Extracted readable text...",
      "wordCount": 1234,
      "fetchedAt": "ISO8601"
    }
  ],
  "metadata": {
    "totalPages": 3,
    "successfulPages": 2,
    "failedPages": 1,
    "totalBytes": 45000,
    "executionTimeSeconds": 12.3
  }
}
```

**citations.json:**
```json
[
  {
    "url": "https://...",
    "title": "Page Title",
    "fetchedAt": "ISO8601",
    "status": "success"
  }
]
```

### Integration Points

| Component | Integration |
|:----------|:------------|
| `BackgroundTaskManager` | Calls `ArtifactStore.save()` after worker completes |
| `BackgroundTask` model | Stores `artifactPath` pointing to task folder |
| BG.05 SummaryGenerator | Reads `result.json`, writes `summary.md` to same folder |
| BG.07 ContextLoading | Reads `summary.md` and `result.json` for LLM context |
| `NSWorkspace` | Reveal in Finder action |

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/BackgroundTasks/Artifacts/ArtifactStore.swift` — Actor: save, read, list, delete, revealInFinder
- `Ora/BackgroundTasks/Artifacts/ArtifactLayout.swift` — Path construction, slug generation, date formatting
- `Ora/BackgroundTasks/Artifacts/ArtifactCleaner.swift` — Periodic cleanup of old artifacts
- `OraTests/BackgroundTasks/ArtifactStoreTests.swift` — Unit tests
- `OraTests/BackgroundTasks/ArtifactLayoutTests.swift` — Path/slug generation tests

### 5.2 Files to Modify

- `Ora/BackgroundTasks/BackgroundTaskManager.swift` — Call `ArtifactStore.save()` after worker completion
- `Ora/BackgroundTasks/BackgroundTask.swift` — Add `artifactPath` field

### 5.3 Tests to Add

- `OraTests/BackgroundTasks/ArtifactStoreTests.swift`:
  - `test_save_createsDirectoryStructure`
  - `test_save_writesResultJSON`
  - `test_save_writesCitationsJSON`
  - `test_save_writesRawHTML_whenPresent`
  - `test_read_loadsResultFromDisk`
  - `test_list_returnsAllArtifactsSortedByDate`
  - `test_delete_removesArtifactFolder`
  - `test_cleanup_removesOlderThanThreshold`
  - `test_cleanup_preservesRecentArtifacts`
- `OraTests/BackgroundTasks/ArtifactLayoutTests.swift`:
  - `test_slug_sanitizesSpecialCharacters`
  - `test_slug_truncatesLongTitles`
  - `test_slug_handlesEmptyInput`
  - `test_datePath_usesLocalTimezone`
  - `test_taskPath_combinesDateAndSlug`

### 5.4 Dependencies/Config

- None (uses Foundation FileManager)

## 6. Acceptance Criteria

- [ ] AC-1: Artifacts are saved to `~/Documents/Ora Research/YYYY-MM-DD/task-<id>-<slug>/`
- [ ] AC-2: `result.json` contains structured extraction data (pages, metadata)
- [ ] AC-3: `citations.json` contains source URLs with titles and timestamps
- [ ] AC-4: Raw HTML is optionally saved under `raw/` subdirectory
- [ ] AC-5: `ArtifactStore.read(taskID:)` returns the stored result
- [ ] AC-6: `ArtifactStore.list()` returns all artifacts sorted by date (newest first)
- [ ] AC-7: `ArtifactStore.revealInFinder(taskID:)` opens the artifact folder in Finder
- [ ] AC-8: Auto-cleanup removes artifacts older than 30 days (configurable)
- [ ] AC-9: Slug generation produces safe filesystem names (no special chars, max 40 chars)
- [ ] AC-10: Directory creation handles concurrent saves without conflict

## 7. Verification Plan

### Automated Tests

- [ ] Artifact save/read round-trip tests
- [ ] Slug sanitization tests (special chars, unicode, empty input, long input)
- [ ] Cleanup threshold tests (mock dates)
- [ ] List ordering tests
- [ ] Concurrent save safety test

### Manual Tests

- [ ] Trigger a background task and verify artifacts appear in Finder
- [ ] Verify `result.json` is valid JSON and human-readable
- [ ] Verify "Reveal in Finder" opens the correct folder
- [ ] Set cleanup threshold to 0 days and verify immediate cleanup

## 8. Performance / Reliability Considerations

- File I/O is minimal (~50KB per typical task); no performance concerns
- Cleanup runs on app launch and every 24h (background timer)
- `FileManager` operations are synchronous but fast for small file counts; run on background actor
- No contention with main pipeline (separate file paths, separate actor)

## 9. Risks & Mitigations

- **Sandbox restrictions on ~/Documents/** — App Sandbox may require user consent for `~/Documents/` access. Mitigation: use `NSOpenPanel` to get initial access, then store security-scoped bookmark. Alternative: use `~/Library/Application Support/Ora/Research/` if sandbox is too restrictive
- **Disk space growth** — Auto-cleanup after 30 days; typical task produces ~50KB; 100 tasks = ~5MB
- **Concurrent saves to same date folder** — `FileManager.createDirectory(withIntermediateDirectories: true)` is safe for concurrent calls
- **Unicode in slugs** — Normalize to ASCII, replace non-alphanumeric with hyphens

## 10. Open Questions

- Should we use `~/Documents/Ora Research/` or `~/Library/Application Support/Ora/Research/`? (Documents is user-visible but may need sandbox entitlement; App Support is invisible)
- Should raw HTML be saved by default or only on user opt-in? (Proposed: opt-in, saves disk space)
- Should cleanup be configurable via Preferences? (Proposed: yes, under a "Background Tasks" section)

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
