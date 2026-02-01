# M.11 - Fuzzy Reminders List Lookup

**Epic:** Maintenance
**Status:** In Progress
**Priority:** P2 (Medium)
**Estimated Effort:** 0.5 days
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

`RemindersStoreProvider.findReminderList(named:)` uses exact case-insensitive matching, which fails when ASR transcription slightly misses the list name (e.g. "groceries" for "Grocery List", "shoping" for "Shopping"). Since reminder list names are user-defined and often spoken casually, the lookup needs a fuzzy fallback. This story adds Jaro-Winkler matching when the exact match fails.

## 2. User Story

As a user, I want Ora to find my reminders list even when I say the name slightly differently than how it's titled, so that filtering by list works reliably by voice.

## 3. Scope

### In Scope

- Two-tier lookup in `RemindersStoreProvider.findReminderList(named:)`: exact case-insensitive match first, then Jaro-Winkler fallback if no exact match.
- Reuse existing `StringSimilarity.jaroWinkler()`.
- Higher threshold (default 0.85) because list names are typically short (1-3 words) and false positives are more disruptive here (wrong list = wrong reminders).
- Return the best-scoring list above threshold, or `nil` if none qualify.
- Unit tests for the fuzzy fallback path.

### Out of Scope

- Fuzzy matching on reminder titles (only list names).
- Returning multiple candidate lists (always return best match or nil).
- Changing the `reminders.list` tool schema (no new parameters).
- Fuzzy matching for `reminders.create` list assignment (separate story if needed).

## 4. Architecture Alignment

- **Component:** `Ora/Tools/Reminders/RemindersStoreProvider.swift`
- **Reuses:** `StringSimilarity` enum (no new dependencies).
- **Threading:** `findReminderList()` is a synchronous method. Fuzzy scoring iterates the calendars array (typically 3-10 lists) — negligible cost.
- **No guardrails needed:** This is a helper used by read-only `reminders.list`.
- **No audit logging needed:** Lookup helper, not a tool execution.

## 5. Implementation Plan

### 5.1 Files to Create

- None.

### 5.2 Files to Modify

- `Ora/Tools/Reminders/RemindersStoreProvider.swift` — Add a fuzzy fallback in `findReminderList(named:)` that scores list titles via `StringSimilarity.jaroWinkler()` and returns the best match above threshold (0.85).
- `Ora/Resources/system-prompt.txt` — Add a note that `reminders.list` list_name filter supports approximate matching, so the LLM can pass the spoken list name directly without worrying about exact title spelling.

### 5.3 Tests to Add

- `OraTests/Tools/Reminders/RemindersToolsTests.swift` — Add tests:
  - `test_findReminderList_exactMatch_preferred` — Verify exact match still works and takes priority.
  - `test_findReminderList_fuzzyFallback_findsCloseMatch` — Verify fuzzy fallback finds "Grocery List" for query "groceries".
  - `test_findReminderList_fuzzyFallback_respectsThreshold` — Verify dissimilar names return nil.
  - `test_findReminderList_fuzzyFallback_returnsBestMatch` — Verify the highest-scoring list is returned when multiple are above threshold.

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [x] AC-1: Exact case-insensitive match is still tried first and preferred. ✅ Verified in `Ora/Tools/Reminders/RemindersStoreProvider.swift`.
- [x] AC-2: When exact match fails, all list titles are scored with `StringSimilarity.jaroWinkler()`. ✅ Verified in `Ora/Tools/Reminders/RemindersStoreProvider.swift`.
- [x] AC-3: Fuzzy fallback returns the best match above threshold (default 0.85), or nil if none qualify. ✅ Verified in `Ora/Tools/Reminders/RemindersStoreProvider.swift`.
- [x] AC-4: `reminders.list` tool behavior is unchanged when exact match succeeds. ✅ Verified in `Ora/Tools/Reminders/RemindersListTool.swift`.
- [x] AC-5: When fuzzy fallback finds a list, the tool returns reminders from that list (existing behavior, new lookup path). ✅ Verified in `Ora/Tools/Reminders/RemindersListTool.swift`.
- [ ] AC-6: Existing tests continue to pass. ⚠️ `./build.sh test` timed out after multiple attempts.
- [x] AC-7: New unit tests cover exact-preferred, fuzzy fallback, threshold filtering, and best-match selection. ✅ `OraTests/Tools/Reminders/RemindersToolsTests.swift`.

## 7. Verification Plan

### Automated Tests

- [x] Unit tests for exact-match-preferred path (`test_findReminderList_exactMatch_preferred`).
- [x] Unit tests for fuzzy fallback (close match, threshold, best selection) (`test_findReminderList_fuzzyFallback_findsCloseMatch`, `test_findReminderList_fuzzyFallback_respectsThreshold`, `test_findReminderList_fuzzyFallback_returnsBestMatch`).

### Manual Tests

- [ ] Say "Show my groceries" — Ora should find the "Grocery List" reminders list.
- [ ] Say "What's on my shoping list" — Ora should find "Shopping" list.
- [ ] Say "Show my xyzgarbage list" — Ora should report no matching list.

## 8. Performance / Reliability Considerations

- Typical users have 3-10 reminder lists. Scoring all of them with Jaro-Winkler is sub-millisecond.
- Exact match remains the fast primary path.

## 9. Risks & Mitigations

- **Risk:** Higher threshold (0.85) might miss legitimate fuzzy matches. **Mitigation:** List names are short, so 0.85 is a reasonable balance — "groceries" vs "Grocery List" scores ~0.87. Can be tuned if needed.
- **Risk:** Fuzzy match returns wrong list. **Mitigation:** Higher threshold reduces false positives. The tool response includes the list name, so the user can catch mismatches before acting on the data.

## 10. Open Questions

- None.

---

## Implementation Summary

**Date:** 2026-02-01  
**Branch:** `feat/m11-fuzzy-reminders-list`  
**Commits:** 1

### Files Changed
- `Ora/Tools/Reminders/RemindersStoreProvider.swift` - add fuzzy fallback for list lookup with 0.85 threshold
- `Ora/Tools/Reminders/RemindersCreateTool.swift` - keep list assignment exact-only
- `Ora/Tools/Reminders/RemindersEditTool.swift` - keep list assignment exact-only
- `OraTests/Tools/Reminders/RemindersToolsTests.swift` - add fuzzy lookup unit coverage
- `Ora/Resources/system-prompt.txt` - note fuzzy list_name matching for reminders.list
- `docs/stories/maintenance/M.11-FUZZY-REMINDERS-LIST.md` - update plan, status, and verification

### Ready for Review
- [x] All acceptance criteria verified (except AC-6; full suite timed out)
- [x] Targeted tests passing (`xcodebuild test -project Ora.xcodeproj -scheme Ora -only-testing:OraTests/Tools/Reminders/RemindersToolsTests`)
- [ ] Working tree clean

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
