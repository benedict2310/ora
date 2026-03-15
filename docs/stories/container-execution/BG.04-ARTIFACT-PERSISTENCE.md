# BG.04 - Artifact Persistence

**Epic:** Background Tasks
**Status:** Ready for Implementation
**Priority:** P1 (High)
**Estimated Effort:** 1.5 days
**Dependencies:** BG.01
**Target:** macOS 26 (Tahoe)

## Summary

Persist task outputs in a deterministic, user-visible folder layout under `~/Documents/Ora Research/`. The store must support save, read, list, cleanup, and Finder reveal so later stories can summarize results and load them back into the agent loop.

## Architecture Context and Reuse Guidance

- Reuse the queue model from BG.01 for task metadata; artifact storage is file-backed, not SwiftData-backed.
- Reuse the existing Finder reveal behavior used by [SystemRevealInFinderTool.swift](/Users/bene/Dev-Source-NoBackup/ora/Ora/Tools/System/SystemRevealInFinderTool.swift).
- Do not add App Sandbox or security-scoped bookmark work in v1. The current app is not sandboxed.

## Resolved Decisions

- Canonical root: `~/Documents/Ora Research/`
- Folder layout is part of the product contract for v1.
- Cleanup default: `30 days`
- Raw HTML persistence exists but defaults to `false`
- No user-facing cleanup preference in this story

## File Touch List

- `Ora/BackgroundTasks/Artifacts/ArtifactStore.swift`
  Purpose: save/read/list/reveal/cleanup actor.
- `Ora/BackgroundTasks/Artifacts/ArtifactLayout.swift`
  Purpose: deterministic path and slug generation.
- `Ora/BackgroundTasks/Artifacts/ArtifactManifest.swift`
  Purpose: codable metadata returned by `list()`.
- `Ora/BackgroundTasks/BackgroundTaskRecord.swift`
  Purpose: persist `artifactPath`.
- `Ora/BackgroundTasks/BackgroundTaskManager.swift`
  Purpose: call artifact persistence after worker success.
- `Ora/AppDelegate.swift`
  Purpose: kick off cleanup on app startup.
- `OraTests/BackgroundTasks/ArtifactStoreTests.swift`
- `OraTests/BackgroundTasks/ArtifactLayoutTests.swift`

## Implementation Steps

1. Implement `ArtifactLayout`.
   Path contract:
   ```text
   ~/Documents/Ora Research/YYYY-MM-DD/task-<shortid>-<slug>/
   ```
   Rules:
   - `shortid` = first 8 lowercase hex chars of UUID
   - slug from task label or first URL host/path hint
   - slug max 40 chars, **allowlist-based** character filter: alphanumeric + hyphen only (reject all other characters including `/`, `..`, path separators)
   - **path canonicalization (SECURITY):** after constructing the full path, call `URL.standardized` or `realpath()` and assert the result starts with the canonical `~/Documents/Ora Research/` root. Add test: `test_slug_rejectsPathTraversal`.
   - **symlink protection (SECURITY):** before writing, verify the target path and all parent directories are not symlinks. Use `FileManager.attributesOfItem(atPath:)[.type]` or `O_NOFOLLOW` semantics. Add test: `test_save_rejectsSymlinkedDirectory`.

2. Implement `ArtifactStore`.
   Required operations:
   - `save(task:workerResult:persistRawHTML:)`
   - `read(taskID:)`
   - `list(limit:)`
   - `revealInFinder(taskID:)`
   - `cleanup(olderThan:)`

3. Persist these files using **atomic writes** (write to a temp file in the same directory, then rename):
   - `result.json`
   - `citations.json`
   - optional `raw/page-<n>.html`
   Atomic writes prevent corrupt artifacts if the app terminates mid-write.

4. Update `BackgroundTaskRecord.artifactPath` after save succeeds.

5. Add startup cleanup trigger from `AppDelegate.onSetupComplete()`.

6. Add disk quota enforcement.
   - Default quota: `500 MB` for `~/Documents/Ora Research/`.
   - Before writing new artifacts, check total directory size.
   - If quota exceeded, refuse the task with an error or trigger early cleanup.
   - Cleanup on filesystem inaccessibility (volume unmounted, permission denied) should degrade gracefully with logging, not crash.

## Tests and Validation

- `test_layout_buildsExpectedTaskPath`
- `test_slug_sanitizesUnsafeCharacters`
- `test_save_writesResultAndCitationFiles`
- `test_save_optionallyWritesRawHTML`
- `test_read_roundTripsSavedArtifact`
- `test_list_returnsNewestFirst`
- `test_revealInFinder_usesArtifactPath`
- `test_cleanup_removesExpiredArtifactsOnly`
- `test_slug_rejectsPathTraversal`
- `test_save_rejectsSymlinkedDirectory`
- `test_save_usesAtomicWrites`
- `test_diskQuota_refusesWriteWhenExceeded`

Manual validation:
- Complete a task and confirm the folder appears under `~/Documents/Ora Research/`.
- Use reveal action and confirm Finder selects the correct folder.

## Acceptance Criteria

- [ ] Artifacts are stored under `~/Documents/Ora Research/` with deterministic task folder names.
- [ ] `result.json` and `citations.json` are always written for successful tasks.
- [ ] Raw HTML can be persisted when requested and is omitted by default.
- [ ] `ArtifactStore.list()` returns lightweight metadata sorted newest-first.
- [ ] `ArtifactStore.revealInFinder(taskID:)` reveals the task folder.
- [ ] Cleanup removes expired artifacts without touching recent ones.
- [ ] Path canonicalization rejects traversal attempts and symlinked directories.
- [ ] File writes are atomic (write-to-temp-then-rename).
- [ ] Disk quota is enforced; new tasks are refused when quota is exceeded.

## Risks and Open Questions

- The storage root is now fixed. If Ora becomes sandboxed later, revisit this story with a migration plan rather than reopening the v1 decision.
- Use `FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)` instead of hardcoding `~/Documents/` to get the canonical path.
- No `NSFileCoordinator` needed in v1 (Ora is the sole writer), but worth noting for future consideration if external processes interact with the folder.
