# MEM.18 - Distiller Quality & Deduplication

**Epic:** Memory System
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** MEM.08, MEM.09
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Improve the quality of memory entries produced by the distiller and strengthen deduplication so that MEMORY.md remains concise, high-signal, and useful. Currently, after ~57 sessions the file has grown to 258 lines with massive redundancy, test noise, and buried real data.

## 2. User Story

As a user, I want MEMORY.md to contain only meaningful, non-redundant information about me so that Ora's memory is useful rather than a wall of repeated test artifacts.

## 3. Problem Analysis

### Current State (observed from production data)

After ~57 distilled sessions, MEMORY.md contains:

| Section | Entries | Unique Signal | Redundancy Rate |
|:--------|:--------|:--------------|:----------------|
| Profile | 12 | ~5 | ~60% |
| Preferences | 23 | ~4 | ~83% |
| People | 28 | ~3 | ~89% |
| Projects | 91 | ~8 | ~91% |
| Ongoing Goals | 59 | ~5 | ~92% |
| **Total** | **213** | **~25** | **~88%** |

### Root Causes

1. **Prompt is too permissive:** The distiller prompt (`memory-distill-prompt.txt`) says "extract stable facts" but doesn't instruct the model to be selective. The local 7B model generates 5-10 entries per session even for trivial "Hello"/"Hi" conversations.

2. **Dedup is exact-match only:** `dedupFingerprint` normalizes whitespace and case, then does exact string comparison. Near-duplicates like "User prefers to initiate actions with 'create' commands" vs "User prefers to initiate actions via direct commands such as 'create'" pass through because their normalized text differs.

3. **No minimum quality bar:** Every non-empty entry from the model is accepted. There's no filtering for low-value entries (e.g., "User greeted with Hello", "Created test item with audit ID X").

4. **No entry cap per session:** A single session can produce unlimited entries. The model tends to generate one entry per message exchange, even for trivial turns.

5. **Test/debug sessions treated identically:** Sessions with synthetic or test patterns (test.create, repeated "Hello") produce the same volume of entries as meaningful conversations.

## 4. Scope

### In Scope

- **Prompt improvements:** Make the distiller prompt more selective and explicit about what NOT to extract
- **Fuzzy deduplication:** Use Jaro-Winkler similarity (already available via `StringSimilarity`) to catch near-duplicate entries
- **Entry cap per session:** Limit memory entries per distillation to a reasonable maximum (e.g., 5-8)
- **Low-value filtering:** Skip entries that match common low-value patterns (greetings, generic tool usage, audit IDs)
- **Section-aware dedup:** Compare new entries against existing entries in the same section using fuzzy matching

### Out of Scope

- Semantic deduplication using embeddings (future — too expensive for on-device)
- Retroactive cleanup of existing MEMORY.md (user can edit manually)
- Changes to session summary generation (summaries are fine)
- Changing the distiller JSON schema

## 5. Architecture Alignment

- **Components:** `Ora/Memory/MemoryDistiller.swift`, `Ora/Memory/MemoryFileManager.swift`, `Ora/Resources/memory-distill-prompt.txt`
- **Existing utility:** `StringSimilarity.jaroWinkler()` in `Ora/Tools/Contacts/StringSimilarity.swift`
- **Concurrency:** No changes — all entry filtering happens synchronously during distillation

## 6. Implementation Plan

### 6.1 Prompt Improvements (`memory-distill-prompt.txt`)

Add explicit negative instructions and quality criteria:

```
Do NOT extract:
- Greetings, small talk, or conversational filler ("User said hello")
- Individual tool invocations or audit IDs ("Created item with audit ID X")
- Observations about the user's interaction style ("User uses greeting phrases")
- Restatements of what the assistant did ("Assistant confirmed completion")
- Anything that only describes THIS session's mechanics, not durable facts

DO extract:
- Concrete personal facts (name, family, location, job)
- Stated preferences with specific content ("prefers morning meetings")
- Decisions made with real consequences ("chose to cancel the trip")
- Named people and relationships ("wife: Maddie")
- Active projects with identifying details

Aim for 0-5 memory entries per session. Most casual sessions should produce 0-2 entries.
If the conversation is trivial (greetings, simple queries), return an empty memory_entries array.
```

### 6.2 Fuzzy Deduplication (`MemoryFileManager.swift`)

Replace exact fingerprint matching with a two-tier approach:

1. **Exact match** (existing): Skip if `dedupFingerprint` matches exactly
2. **Fuzzy match** (new): For entries in the same section, compute Jaro-Winkler similarity between the new entry's content and each existing entry's content. Skip if similarity >= 0.85

The fuzzy check runs only within the same section to keep it O(n) per section rather than O(n^2) across all entries.

### 6.3 Entry Cap (`MemoryDistiller.swift`)

After parsing the model's output, truncate `memoryEntries` to a maximum of 8 entries, keeping the first N (the model's ordering reflects priority).

### 6.4 Low-Value Filter (`MemoryDistiller.swift`)

Add a post-parse filter that drops entries matching common low-value patterns:

- Content contains "audit ID" or "audit_id" (case-insensitive)
- Content matches patterns like "User greeted with", "User said hello/hi"
- Content is purely about tool invocation mechanics ("Created N items using X tool")
- Content length < 15 characters (too vague to be useful)

### 6.5 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Resources/memory-distill-prompt.txt` | Add negative instructions and entry limit guidance |
| `Ora/Memory/MemoryDistiller.swift` | Add entry cap, low-value filter in `toPayload()` |
| `Ora/Memory/MemoryFileManager.swift` | Add fuzzy dedup using Jaro-Winkler in `deduplicatedEntries()` |
| `Ora/Tools/Contacts/StringSimilarity.swift` | Potentially move to `Ora/Utilities/` if reuse warrants it (or just reference directly) |

### 6.6 Tests to Add

| Test File | Coverage |
|:----------|:---------|
| `OraTests/MemoryDistillerTests.swift` | Test entry cap, low-value filtering |
| `OraTests/MemoryUpdatePolicyTests.swift` | Test fuzzy dedup with near-duplicate entries |

## 7. Acceptance Criteria

- [ ] AC-1: Distiller prompt explicitly instructs model to be selective (0-5 entries for typical sessions)
- [ ] AC-2: Near-duplicate entries (Jaro-Winkler >= 0.85 within same section) are rejected
- [ ] AC-3: Entries containing audit IDs or trivial greetings are filtered out
- [ ] AC-4: Maximum 8 memory entries per distillation
- [ ] AC-5: A test session with only "Hello"/"Hi" messages produces 0 memory entries
- [ ] AC-6: A session with real content (name, preferences, decisions) still produces correct entries
- [ ] AC-7: Manual E2E test starts with a clean/reset memory folder (delete existing MEMORY.md + Summaries before testing)

## 8. Verification Plan

### Automated Tests

- [ ] Unit test: fuzzy dedup rejects "User prefers X" vs "User prefers X via Y" (same section, JW >= 0.85)
- [ ] Unit test: fuzzy dedup allows genuinely different entries in the same section
- [ ] Unit test: low-value filter drops audit ID entries
- [ ] Unit test: low-value filter drops greeting-only entries
- [ ] Unit test: entry cap limits output to 8
- [ ] Unit test: real content passes through filters unchanged

### Manual Tests

- [ ] Run Ora, have a trivial conversation ("Hello", "Hi"), verify MEMORY.md gets 0 new entries
- [ ] Run Ora, share real personal info ("My name is X, I prefer morning meetings"), verify entries appear correctly
- [ ] Inspect MEMORY.md after 5+ sessions and verify no excessive duplication

## 9. Performance / Reliability Considerations

- Fuzzy dedup adds O(n*m) Jaro-Winkler comparisons per section (n=new entries, m=existing entries). With typical section sizes of 20-50, this is negligible.
- Entry cap and filters run on the parsed JSON result, not on the LLM call, so no latency impact on generation.

## 10. Risks & Mitigations

- **Risk:** Overly aggressive filtering drops valid entries → **Mitigation:** Tune thresholds conservatively (JW 0.85 is high similarity, 8-entry cap is generous). Add escape hatch: entries with a `normalized_key` bypass fuzzy dedup (explicit dedup only).
- **Risk:** Prompt changes cause model to return invalid JSON → **Mitigation:** Only add instructional text, don't change the schema. Existing retry logic handles parse failures.
- **Risk:** Existing MEMORY.md bloat persists → **Mitigation:** Out of scope for this story (user can clean up manually). New entries will be high quality going forward.

## 11. Open Questions

- Should we provide a one-time "compact MEMORY.md" utility that deduplicates the existing file? (Could be a follow-up story)
- What Jaro-Winkler threshold works best empirically? Start at 0.85 and adjust based on testing.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
