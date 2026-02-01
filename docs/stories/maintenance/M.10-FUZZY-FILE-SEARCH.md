# M.10 - Fuzzy File Search

**Epic:** Maintenance
**Status:** Not Started
**Priority:** P2 (Medium)
**Estimated Effort:** 0.5 days
**Dependencies:** None
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

`system.search_files` uses Spotlight's `CONTAINS[cd]` predicate, which handles case and diacritics but not ASR transcription errors (e.g. "bujit report" for "budget report", "reesearch notes" for "research notes"). This story adds a Jaro-Winkler re-ranking pass over Spotlight results and a fuzzy broadened retry when the initial query returns no results, improving voice-driven file search reliability.

## 2. User Story

As a user, I want Ora to find my files even when speech recognition slightly garbles the filename, so that I can locate documents by voice without frustration.

## 3. Scope

### In Scope

- **Re-ranking pass:** After Spotlight returns results, score each filename against the query using `StringSimilarity.jaroWinkler()` and sort by descending score. This improves relevance ordering when Spotlight returns many loose `CONTAINS` matches.
- **Broadened retry:** If Spotlight returns zero results, retry with a relaxed predicate (e.g. individual words from the query joined by OR) and then fuzzy-filter the results above threshold.
- Reuse existing `StringSimilarity.jaroWinkler()`.
- Configurable threshold (default 0.80).
- Unit tests for re-ranking and retry paths.

### Out of Scope

- Replacing Spotlight with a custom file index.
- Full-text content search (only filenames).
- Phonetic filename variants.
- Searching inside file contents.

## 4. Architecture Alignment

- **Component:** `Ora/Tools/System/SystemSearchFilesTool.swift`
- **Reuses:** `StringSimilarity` enum (no new dependencies).
- **Threading:** Spotlight query runs on `@MainActor` with a 5-second timeout. Re-ranking is a pure in-memory sort — negligible cost.
- **No guardrails needed:** Read-only tool.
- **No audit logging needed:** Search tools don't modify state.

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- None.

### 5.2 Files to Modify

- `Ora/Tools/System/SystemSearchFilesTool.swift` — After Spotlight returns results, re-rank by `StringSimilarity.jaroWinkler(query, filename)`. If Spotlight returns zero results, retry by splitting the query into words and using an OR predicate, then fuzzy-filter above threshold.
- `Ora/Resources/system-prompt.txt` — Update rule 12 (SYSTEM NAVIGATION) to note that `system.search_files` supports fuzzy matching, so the LLM can pass voice-transcribed filenames directly.

### 5.3 Tests to Add

- `OraTests/Tools/System/SystemToolsTests.swift` — Add tests:
  - `test_searchFiles_reranking_ordersByRelevance` — Verify filenames closer to query sort first.
  - `test_searchFiles_fuzzyRetry_findsTypo` — Verify broadened retry + fuzzy filter finds files for misspelled queries.
  - `test_searchFiles_fuzzyRetry_respectsThreshold` — Verify dissimilar results are filtered out.

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [ ] AC-1: When Spotlight returns results, they are re-ranked by Jaro-Winkler similarity to the query.
- [ ] AC-2: When Spotlight returns zero results, a broadened retry is attempted using individual query words.
- [ ] AC-3: Broadened retry results are filtered by Jaro-Winkler threshold (default 0.80).
- [ ] AC-4: Results respect the `limit` parameter.
- [ ] AC-5: The 5-second Spotlight timeout is preserved.
- [ ] AC-6: Existing tests continue to pass.
- [ ] AC-7: New unit tests cover re-ranking and retry paths.

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for re-ranking with mock Spotlight results.
- [ ] Unit tests for broadened retry path.
- [ ] Unit tests for threshold filtering.

### Manual Tests

- [ ] Say "Find bujit report" — Ora should find "Budget Report.xlsx" if it exists.
- [ ] Say "Search for reesearch notes" — Ora should find "Research Notes.md" if it exists.
- [ ] Say "Find xyzgarbage" — Ora should return no results.

## 8. Performance / Reliability Considerations

- Re-ranking a set of ≤20 Spotlight results with Jaro-Winkler is sub-millisecond.
- Broadened retry uses the same Spotlight infrastructure and respects the existing 5-second timeout.
- No additional filesystem I/O beyond what Spotlight already provides.

## 9. Risks & Mitigations

- **Risk:** Broadened retry (OR of individual words) may return too many irrelevant results. **Mitigation:** Jaro-Winkler threshold filtering removes weak matches; limit parameter caps output.
- **Risk:** Single-word queries can't be split for broadened retry. **Mitigation:** For single-word queries, the broadened retry is equivalent to the original query — no harm, just no extra benefit.

## 10. Open Questions

- None.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
