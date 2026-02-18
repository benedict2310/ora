# MEM.19 - Fix Memory Distiller Deduplication & Context Truncation

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 0.5 days
**Dependencies:** MEM.18
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Fix the root cause of duplicate entries in MEMORY.md that slip through MEM.18's 3-tier dedup system, and clean up the ~30 duplicate entries that accumulated in production.

### Problem Analysis

**Observed state:** MEMORY.md (6.6KB, 47 lines) contained:
- ~10 near-identical "testing" entries in Projects (Jaro-Winkler scores 0.88-0.97)
- 3 contradictory People entries (conflicting family member lists)
- 4 duplicate Ongoing Goals entries (same calendar-checking goal, different wordings)
- Duplicate "shared calendar" entries in Projects

**Root causes identified:**

- **RC-1: Context truncation (primary).** `MemoryDistiller.existingMemoryContextCharacterLimit` was set to 2,000 chars. MEMORY.md had grown to 6,600 chars. The LLM only saw the first ~30% of the file (Profile + Preferences), so it generated "new" entries that duplicated content in Projects and Ongoing Goals that it couldn't see.
- **RC-2: No cross-section fuzzy dedup.** `hasFuzzyDuplicate` only checked within the same section. An entry in Projects like "User wants to check calendar" wasn't caught by a similar entry in Ongoing Goals.
- **RC-3: Testing sessions generating memory.** The distill prompt lacked explicit instructions to skip testing/debugging sessions, so the LLM generated entries like "User has initiated tests for provider setup..." across multiple sessions.
- **RC-4: No dedup logging.** `MemoryFileManager` had no logging, making it impossible to verify whether dedup was executing or failing silently.

## 2. User Story

As a user, I want MEMORY.md to remain clean and free of duplicates even after many sessions, so that Ora's long-term memory stays useful and trustworthy.

## 3. Scope

### In Scope

- **Increase context limit** from 2,000 → 6,000 chars (fixes RC-1)
- **Add cross-section fuzzy dedup** with 0.90 threshold (fixes RC-2)
- **Enhance distill prompt** with testing session guidance (fixes RC-3)
- **Add Logger to MemoryFileManager** with dedup decision logging (fixes RC-4)
- **Manual cleanup of MEMORY.md** to remove accumulated duplicates
- **Tests** for cross-session and cross-section dedup scenarios

### Out of Scope

- Retroactive cleanup utility (manual cleanup sufficient for now)
- Semantic dedup via embeddings
- Changes to dedup threshold values (0.85 same-section / 0.90 cross-section work well)

## 4. Implementation

### 4.1 Files Modified

| File | Change |
|:-----|:-------|
| `~/.ora/memory/MEMORY.md` | Manual cleanup: removed ~30 duplicate entries, kept most recent People entry, consolidated Ongoing Goals |
| `Ora/Memory/MemoryDistiller.swift` | Increased `existingMemoryContextCharacterLimit` from 2,000 → 6,000 |
| `Ora/Memory/MemoryFileManager.swift` | Added `Logger`, cross-section fuzzy dedup (0.90 threshold), dedup decision logging |
| `Ora/Resources/memory-distill-prompt.txt` | Added testing/debugging session guidance, anti-rewording instructions, stricter selectivity |
| `OraTests/MemoryUpdatePolicyTests.swift` | Added 3 new tests: cross-session fuzzy dedup, cross-section fuzzy dedup, cross-section distinct content |

### 4.2 Context Limit Increase (RC-1)

Changed `existingMemoryContextCharacterLimit` default from `2_000` to `6_000` in `MemoryDistiller.init()`.

The distiller uses a separate LLM call (not part of the main conversation), so the larger context is affordable. At 6,000 chars, even a well-populated MEMORY.md (typical range: 2-8KB) will be shown to the LLM nearly in full, allowing it to avoid generating duplicates.

### 4.3 Cross-Section Fuzzy Dedup (RC-2)

Added a final dedup tier in `MemoryFileManager.deduplicatedEntries()`:

1. **Tier 1 (existing):** Exact fingerprint match → reject
2. **Tier 2 (existing):** Normalized key match → reject
3. **Tier 3 (existing):** Same-section fuzzy match (Jaro-Winkler >= 0.85) → reject
4. **Tier 4 (new):** Cross-section fuzzy match (Jaro-Winkler >= 0.90) → reject

The cross-section threshold is stricter (0.90 vs 0.85) to avoid false positives across naturally different section contexts. This catches the observed pattern where "User wants to check calendar" appeared in both Projects and Ongoing Goals.

### 4.4 Distill Prompt Enhancements (RC-3)

Added two new sections to `memory-distill-prompt.txt`:

- **Testing and debugging:** Explicit instruction that testing sessions should produce 0 entries unless a durable preference is stated.
- **Anti-rewording:** "Do NOT generate entries that are minor rewordings of existing memory."
- **Stricter selectivity:** "When in doubt, prefer 0 entries over a marginal or redundant entry."

### 4.5 Dedup Logging (RC-4)

Added `Logger(subsystem: "com.ora.app", category: "memory")` to `MemoryFileManager`. Each dedup decision is now logged:

- Fingerprint match rejections
- Normalized key rejections
- Same-section fuzzy match rejections (with score)
- Cross-section fuzzy match rejections (with score)
- Accepted entries

Visible via: `./build.sh logs --category memory`

### 4.6 MEMORY.md Cleanup

Removed from MEMORY.md:
- 10 near-identical "User has initiated tests for provider setup..." entries
- 3 additional testing-related entries
- 1 duplicate "shared calendar" entry (kept in Profile)
- 2 contradictory People entries (kept most recent: "Family members are Maddie and Sophia only")
- 3 duplicate Ongoing Goals entries (kept most comprehensive one)
- 1 stale "testing protocol" preference

Retained: 12 genuine entries across all 5 sections.

## 5. Acceptance Criteria

- [x] AC-1: `existingMemoryContextCharacterLimit` increased to 6,000
- [x] AC-2: Cross-section fuzzy dedup rejects entries with JW >= 0.90 across different sections
- [x] AC-3: Cross-section dedup allows genuinely different content across sections
- [x] AC-4: Distill prompt instructs LLM to skip testing/debugging sessions
- [x] AC-5: MemoryFileManager logs dedup decisions at info level
- [x] AC-6: MEMORY.md cleaned of all duplicate and contradictory entries
- [x] AC-7: All existing tests pass (1410/1410)
- [x] AC-8: New tests cover cross-session and cross-section dedup scenarios

## 6. Verification

### Automated Tests (3 new)

- [x] `test_appendEntries_crossSessionFuzzyDuplicate_rejectsNearIdenticalRewordings` — Simulates the exact production failure: two `appendEntries` calls with JW ≈ 0.96 content
- [x] `test_appendEntries_crossSectionFuzzyDuplicate_rejectsNearIdenticalAcrossSections` — Entries in Ongoing Goals and Projects with JW ≈ 0.95
- [x] `test_appendEntries_crossSectionDistinctContent_allowsBothEntries` — Ensures genuinely different content is not falsely rejected

### Manual Verification

- [ ] Run Ora with test conversations, verify dedup logging in `./build.sh logs --category memory`
- [ ] Inspect MEMORY.md after multiple sessions — verify no new duplicates
- [ ] Run a testing-style session — verify 0 memory entries generated
