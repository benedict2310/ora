# M.10 - Fuzzy File Search

**Epic:** Maintenance
**Status:** In Progress
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

## 5. Implementation Plan

### 5.1 Files to Create

- None.

### 5.2 Files to Modify

- `Ora/Tools/System/SystemSearchFilesTool.swift` — Add helper functions for Spotlight predicates, fuzzy scoring, re-ranking, and threshold filtering. Re-rank results from the initial Spotlight query. If zero results, retry with an OR predicate built from query terms, then filter by Jaro-Winkler threshold.
- `Ora/Resources/system-prompt.txt` — Update rule 12 (SYSTEM NAVIGATION) to note that `system.search_files` supports fuzzy matching, so the LLM can pass voice-transcribed filenames directly.

### 5.3 Tests to Add

- `OraTests/Tools/System/SystemToolsTests.swift` — Add tests:
  - `test_searchFiles_reranking_ordersByRelevance` — Verify filenames closer to query sort first.
  - `test_searchFiles_fuzzyRetry_findsTypo` — Verify broadened retry + fuzzy filter finds files for misspelled queries.
  - `test_searchFiles_fuzzyRetry_respectsThreshold` — Verify dissimilar results are filtered out.

### 5.4 Dependencies/Config

- None.

## 6. Acceptance Criteria

- [x] AC-1: When Spotlight returns results, they are re-ranked by Jaro-Winkler similarity to the query. ✅ Verified in `Ora/Tools/System/SystemSearchFilesTool.swift`.
- [x] AC-2: When Spotlight returns zero results, a broadened retry is attempted using individual query words. ✅ Verified in `Ora/Tools/System/SystemSearchFilesTool.swift`.
- [x] AC-3: Broadened retry results are filtered by Jaro-Winkler threshold (default 0.80). ✅ Verified in `Ora/Tools/System/SystemSearchFilesTool.swift`.
- [x] AC-4: Results respect the `limit` parameter. ✅ Verified in `Ora/Tools/System/SystemSearchFilesTool.swift` and `OraTests/Tools/System/SystemToolsTests.swift`.
- [x] AC-5: The 5-second Spotlight timeout is preserved. ✅ Verified in `Ora/Tools/System/SystemSearchFilesTool.swift`.
- [x] AC-6: Existing tests continue to pass. ✅ `./build.sh test`.
- [x] AC-7: New unit tests cover re-ranking and retry paths. ✅ `OraTests/Tools/System/SystemToolsTests.swift`.

## 7. Verification Plan

### Automated Tests

- [x] Unit tests for re-ranking with mock Spotlight results (`test_searchFiles_reranking_ordersByRelevance`).
- [x] Unit tests for broadened retry path (`test_searchFiles_broadenedQueryTerms_splitsWords`, `test_searchFiles_fuzzyRetry_findsTypo`).
- [x] Unit tests for threshold filtering (`test_searchFiles_fuzzyRetry_respectsThreshold`).

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

**Date:** 2026-02-01  
**Branch:** `feat/m10-fuzzy-file-search`  
**Commits:** 5

### Files Changed
- `Ora/Tools/System/SystemSearchFilesTool.swift` - add fuzzy re-ranking, broadened retry, and scoring helpers
- `OraTests/Tools/System/SystemToolsTests.swift` - add unit coverage for re-ranking and fuzzy retry paths
- `Ora/Resources/system-prompt.txt` - note fuzzy file search in system navigation rules
- `docs/stories/maintenance/M.10-FUZZY-FILE-SEARCH.md` - update plan, status, and verification

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing (`./build.sh test`)
- [x] Working tree clean

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-01T11:45:00Z
**Commit reviewed:** 3f454e2
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
- None

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

(TBD after merge.)
