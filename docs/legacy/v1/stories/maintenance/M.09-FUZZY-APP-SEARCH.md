# M.09 - Fuzzy App Search

**Epic:** Maintenance
**Status:** Complete
**Priority:** P2 (Medium)
**Estimated Effort:** 0.5 days
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

`system.search_apps` currently uses substring `contains` matching, which fails when ASR transcription introduces minor errors (e.g. "Spottify" for Spotify, "Keenote" for Keynote). Since Ora is a voice assistant, all user-facing search tools must be resilient to transcription inaccuracies. This story adds a Jaro-Winkler fuzzy fallback that activates when the existing substring match returns no results.

## 2. User Story

As a user, I want Ora to find the app I asked for even when speech recognition slightly misspells the name, so that I don't have to repeat myself or spell it out.

## 3. Scope

### In Scope

- Two-tier search in `SystemSearchAppsTool.searchApps()`: try substring `contains` first, fall back to Jaro-Winkler scoring if no results.
- Reuse existing `StringSimilarity.jaroWinkler()` from `Ora/Tools/Contacts/StringSimilarity.swift`.
- Configurable threshold (default 0.80).
- Return fuzzy results sorted by descending score.
- Include match score in result metadata (for debugging/logging).
- Unit tests for the fuzzy fallback path.

### Out of Scope

- Changing the substring-match path (it remains the primary, fast path).
- Bundle-ID-based search or Spotlight-based app search.
- Phonetic app name variants.
- Moving `StringSimilarity` to a shared module (it's already accessible project-wide).

## 4. Architecture Alignment

- **Component:** `Ora/Tools/System/SystemSearchAppsTool.swift`
- **Reuses:** `StringSimilarity` enum (no new dependencies).
- **Threading:** `searchApps()` runs synchronously on the calling async context. Fuzzy matching iterates installed apps in-memory — fast enough for the ~200-400 apps typical on macOS.
- **No guardrails needed:** This is a read-only tool (`ToolKind.read`).
- **No audit logging needed:** Search tools don't modify state.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None.

### 5.2 Files to Modify

- `Ora/Tools/System/SystemSearchAppsTool.swift` — Add fuzzy fallback in `searchApps()` when substring match returns empty. Collect all app names during filesystem scan, then score with `StringSimilarity.jaroWinkler()` and filter by threshold.
- `Ora/Resources/system-prompt.txt` — Update rule 12 (SYSTEM NAVIGATION) to note that `system.search_apps` supports fuzzy matching, so the LLM can pass voice-transcribed app names directly without worrying about exact spelling.

### 5.3 Tests to Add

- `OraTests/Tools/System/SystemToolsTests.swift` — Add tests:
  - `test_searchApps_substringMatch_preferred` — Verify substring match is still used when it finds results.
  - `test_searchApps_fuzzyFallback_findsTypo` — Verify fuzzy fallback finds "Spotify" when query is "Spottify".
  - `test_searchApps_fuzzyFallback_respectsThreshold` — Verify very dissimilar queries return no results.
  - `test_searchApps_fuzzyFallback_sortedByScore` — Verify results are ordered by descending similarity.

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [x] AC-1: When substring match finds results, behavior is unchanged (no fuzzy scoring runs).
- [x] AC-2: When substring match returns empty, fuzzy fallback scores all discovered app names using `StringSimilarity.jaroWinkler()`.
- [x] AC-3: Fuzzy results are filtered by threshold (default 0.80) and sorted by descending score.
- [x] AC-4: Fuzzy results respect the `limit` parameter.
- [x] AC-5: Existing tests continue to pass.
- [x] AC-6: New unit tests cover the fuzzy fallback path (typo match, threshold filtering, score ordering).

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for substring-preferred path.
- [ ] Unit tests for fuzzy fallback path (typo scenarios).
- [ ] Unit tests for threshold filtering and score ordering.

### Manual Tests

- [ ] Say "Open Spottify" — Ora should find Spotify.
- [ ] Say "Search for Keenote" — Ora should find Keynote.
- [ ] Say "Search for xyzgarbage" — Ora should return no results.

## 8. Performance / Reliability Considerations

- Filesystem scan of `/Applications` + `/System/Applications` typically yields 200-400 `.app` bundles. Jaro-Winkler scoring all of them takes <10ms — no performance concern.
- Substring match remains the fast primary path; fuzzy only runs as fallback.

## 9. Risks & Mitigations

- **Risk:** False positives from low threshold. **Mitigation:** Default threshold 0.80 is conservative; can be tuned upward if false matches are observed.
- **Risk:** App names with common words (e.g. "Music", "News") might fuzzy-match unrelated queries. **Mitigation:** Short common names score poorly on Jaro-Winkler unless the query is very similar.

## 10. Open Questions

- None.

---

## Implementation Summary

- Added Jaro-Winkler fallback in `SystemSearchAppsTool.searchApps()` with a 0.80 threshold, using `StringSimilarity`.
- App results now include `match_score` metadata for fuzzy matches (rounded to 2 decimals).
- Added fuzzy-matching unit tests (typo match, threshold, ordering, limit, threshold constant).
- Updated system prompt to note fuzzy matching for `system.search_apps`.

## Code Review Findings

(TBD by review agent.)

## Completion Status

Complete (commit 8b4a250, February 1, 2026).
