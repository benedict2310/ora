# MEM.18 - Distiller Quality & Deduplication

**Epic:** Memory System
**Status:** Complete
**Priority:** P1 (High)
**Estimated Effort:** 3 days
**Dependencies:** MEM.08, MEM.09
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Improve the quality of memory entries produced by the distiller and strengthen deduplication so that MEMORY.md remains concise, high-signal, and useful. Currently, after ~57 sessions the file has grown to 258 lines with ~88% redundancy, test noise, and buried real data.

### Problem Analysis

**Current state (observed from production data):** After ~57 distilled sessions, MEMORY.md contains ~213 entries but only ~25 carry unique signal (~88% redundancy). Plus 3 orphaned `## Memory Update` sections from an older code path.

**Root causes (prioritized by impact):**

- **RC-1: Tool messages leak into the transcript.** `renderTranscript()` includes `.tool` role messages verbatim — the model extracts tool mechanics as "facts." Accounts for ~50% of junk entries.
- **RC-2: Distiller has no awareness of existing memory.** Each session is distilled in isolation, causing semantic duplicates.
- **RC-3: No minimum session threshold.** 55/57 sessions are trivial/synthetic but each generates 5-10 entries.
- **RC-4: Prompt is too permissive.** No negative instructions — model extracts interaction patterns and session mechanics.
- **RC-5: Dedup is exact-match only.** Near-identical entries with different wording pass through.
- **RC-6: Section misclassification.** Model doesn't understand section semantics; prompt lacks section descriptions.

## 2. User Story

As a user, I want MEMORY.md to contain only meaningful, non-redundant information about me so that Ora's memory is useful rather than a wall of repeated noise.

## 3. Scope

### In Scope

- **Strip tool messages from transcript** (fixes RC-1)
- **Feed existing MEMORY.md as context to the distiller** (fixes RC-2)
- **Minimum session threshold — skip trivial sessions** (fixes RC-3)
- **Prompt improvements with negative instructions and section descriptions** (fixes RC-4, RC-6)
- **Fuzzy deduplication using Jaro-Winkler** (fixes RC-5)
- **Entry cap per session** (safety net)
- **Low-value content filter** (safety net)
- **Clean up orphaned "Memory Update" sections** from existing MEMORY.md template

### Out of Scope

- Semantic deduplication using embeddings (future — too expensive for on-device)
- Changes to session summary generation (summaries are fine)
- Changing the distiller JSON schema
- Retroactive cleanup utility for existing MEMORY.md (follow-up story)

## 4. Architecture Alignment

- **Components:** `Ora/Memory/MemoryDistiller.swift`, `Ora/Memory/MemoryFileManager.swift`, `Ora/Resources/memory-distill-prompt.txt`
- **Existing utility:** `StringSimilarity.jaroWinkler()` in `Ora/Tools/Contacts/StringSimilarity.swift`
- **Concurrency:** No changes — all entry filtering happens synchronously during distillation

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

No new files required.

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Resources/memory-distill-prompt.txt` | Rewrite with negative instructions, section descriptions, selectivity guidance |
| `Ora/Memory/MemoryDistiller.swift` | Strip `.tool` messages in `renderTranscript()`, inject existing MEMORY.md as context, add minimum session threshold, add entry cap + low-value filter |
| `Ora/Memory/MemoryFileManager.swift` | Add fuzzy dedup in `deduplicatedEntries()`, clean up orphaned sections |

### 5.3 Tests to Add

| Test File | Coverage |
|:----------|:---------|
| `OraTests/MemoryDistillerTests.swift` | Tool message stripping, minimum session threshold, entry cap, low-value filter, existing memory injection |
| `OraTests/MemoryUpdatePolicyTests.swift` | Fuzzy dedup with near-duplicate entries, orphaned section cleanup |

### 5.4 Strip Tool Messages from Transcript (RC-1 — highest impact)

In `MemoryDistiller.renderTranscript()`, filter out `.tool` role messages before rendering. The model doesn't need to see `[ToolResult: test.create] Created (auditId=...)` — it adds noise and causes the model to extract tool mechanics as "facts."

```swift
private func renderTranscript(_ messages: [Session.Message]) -> String {
    let filtered = messages.filter { $0.role != .tool }
    // ... existing rendering ...
}
```

This single change eliminates the source of ~50% of junk entries.

### 5.5 Feed Existing Memory as Context (RC-2 — second highest impact)

Before calling the LLM, read current MEMORY.md and inject it into the prompt:

```
Here is what Ora already remembers (MEMORY.md):
---
[existing MEMORY.md content, truncated to ~2000 chars]
---

Only extract NEW information not already captured above.
If the conversation adds nothing new, return empty memory_entries.
```

This lets the model do semantic dedup at generation time — far more powerful than post-hoc string matching. Truncate to avoid blowing the context window; prioritize Profile and Preferences sections (most likely to have duplicates).

### 5.6 Minimum Session Threshold (RC-3)

Skip distillation entirely for sessions that are too short to contain meaningful content:

- Fewer than 3 user messages, OR
- Total user content length under 50 characters

These sessions still get a summary file (for completeness) but produce 0 memory entries.

```swift
let userMessages = messages.filter { $0.role == .user }
let totalUserChars = userMessages.reduce(0) { $0 + $1.content.count }
if userMessages.count < 3 || totalUserChars < 50 {
    // Write summary only, skip memory entry extraction
}
```

### 5.7 Prompt Improvements (RC-4, RC-6)

Rewrite `memory-distill-prompt.txt` with:

**Negative instructions (what NOT to extract):**
```
Do NOT extract:
- Greetings, small talk, or conversational filler ("User said hello")
- Tool invocations, audit IDs, or system internals ("Created item with audit ID X")
- Observations about the user's interaction style ("User uses greeting phrases")
- Restatements of what the assistant did ("Assistant confirmed completion")
- Anything that describes THIS session's mechanics rather than durable facts about the user
- Vague or generic statements ("User engaged in multiple interactions")
```

**Section descriptions (so the model classifies correctly):**
```
Section definitions:
- profile: Identity, demographics, job, location (e.g., "Name: Benedict", "Works at Acme Corp")
- preferences: Explicit stated likes/dislikes with specific content (e.g., "Prefers morning meetings", "Likes spicy food")
- people: Named individuals and their relationship to the user (e.g., "Wife: Maddie", "Manager: Roland")
- projects: Active named projects or goals with identifying details (e.g., "Working on Project Aura")
- ongoing_goals: Recurring objectives or commitments (e.g., "Training for a marathon", "Learning German")
```

**Selectivity guidance:**
```
Aim for 0-5 memory entries per session. Most sessions should produce 0-2 entries.
A casual "Hello" conversation should produce 0 entries.
Only extract something if you are confident it is a durable fact or preference the user would want remembered.
```

### 5.8 Fuzzy Deduplication (RC-5)

In `MemoryFileManager.deduplicatedEntries()`, add a second pass after exact-match:

1. **Exact match** (existing): Skip if `dedupFingerprint` matches exactly
2. **Fuzzy match** (new): For each new entry, compare its content against all existing entries in the **same section** using Jaro-Winkler. Skip if similarity >= 0.85

Entries with a `normalized_key` bypass fuzzy dedup (they use key-based dedup only).

### 5.9 Entry Cap (safety net)

After parsing the model's output, truncate `memoryEntries` to a maximum of 8 entries. The model's ordering reflects priority, so keep the first N.

### 5.10 Low-Value Content Filter (safety net)

Post-parse filter in `DistillationEnvelope.toPayload()` that drops entries matching:

- Contains "audit ID" or "audit_id" or a UUID pattern (case-insensitive)
- Matches greeting patterns: "User greeted", "User said hello", "User consistently uses greeting"
- Pure tool mechanics: "Created N items using X tool"
- Too short to be meaningful: content length under 20 characters

### 5.11 Clean Up Orphaned Sections

The `## Memory Update` headings (lines 6-26 in current MEMORY.md) are from an older code path. The `ensureRequiredSections()` method in MemoryFileManager should strip unrecognized `##` sections, or at minimum the template should not include them. Add a migration step that removes these on next write.

## 6. Acceptance Criteria

- [x] AC-1: `.tool` role messages are excluded from the transcript sent to the distiller
- [x] AC-2: Existing MEMORY.md content is included in the distiller prompt as context
- [x] AC-3: Sessions with fewer than 3 user messages or fewer than 50 chars user content produce 0 memory entries
- [x] AC-4: Distiller prompt includes explicit negative instructions and section descriptions
- [x] AC-5: Near-duplicate entries (Jaro-Winkler >= 0.85 within same section) are rejected
- [x] AC-6: Entries containing audit IDs, UUIDs, or trivial greetings are filtered out
- [x] AC-7: Maximum 8 memory entries per distillation
- [x] AC-8: A session with real content (name, preferences, decisions) still produces correct entries in the right sections
- [ ] AC-9: Manual E2E test starts with a clean/reset memory folder (delete existing MEMORY.md + Summaries before testing)

## 7. Verification Plan

### Automated Tests

- [x] Unit test: `renderTranscript` excludes `.tool` messages
- [x] Unit test: sessions below minimum threshold produce 0 memory entries (summary still written)
- [x] Unit test: fuzzy dedup rejects "User prefers X" vs "User prefers X via Y" (same section, JW >= 0.85)
- [x] Unit test: fuzzy dedup allows genuinely different entries in the same section
- [x] Unit test: low-value filter drops entries with audit IDs / UUIDs
- [x] Unit test: low-value filter drops greeting-only entries
- [x] Unit test: entry cap limits output to 8
- [x] Unit test: real content passes through all filters unchanged
- [x] Unit test: existing MEMORY.md content is present in the LLM prompt

### Manual Tests

- [ ] Reset memory folder, run Ora, have a trivial conversation ("Hello", "Hi"), verify MEMORY.md gets 0 new entries
- [ ] Run Ora, share real info ("My name is Alex, I prefer evening workouts"), verify entries appear in correct sections
- [ ] Run 5+ sessions, inspect MEMORY.md — verify no excessive duplication and correct section assignment
- [ ] Run a session that uses tools (create event, search contacts), verify tool mechanics don't appear in MEMORY.md

---

## Implementation Summary

**Date:** 2026-02-16
**Branch:** `feat/MEM.18-distiller-quality`
**Commits:** 2
**Implemented by:** codex (complexity score: 8/10)
**Reviewed by:** pi (1 iteration)

### Files Modified
- `Ora/Memory/MemoryDistiller.swift` — Added tool message stripping, minimum session threshold, existing memory context injection, low-value content filter, entry cap (8)
- `Ora/Memory/MemoryFileManager.swift` — Added fuzzy Jaro-Winkler dedup (>= 0.85), orphaned `## Memory Update` section cleanup
- `Ora/Resources/memory-distill-prompt.txt` — Rewritten with negative instructions, section definitions, selectivity guidance

### Tests Added/Updated
- `OraTests/MemoryDistillerTests.swift` — 8+ new tests for tool stripping, threshold skip, memory injection, low-value filter, entry cap, valid content pass-through
- `OraTests/MemoryUpdatePolicyTests.swift` — 3+ new tests for fuzzy dedup and orphaned section cleanup
- `OraTests/MemoryFileManagerTests.swift` — Updated for new normalization/migration behavior

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-02-16T08:45:00Z
**Commit reviewed:** 3a12435
**Iteration:** 1

### Summary
- Files reviewed: 14 (includes tests and docs)
- Build status: Pass

### Issues Found

#### P0 - Critical (Must fix)
- [x] None

#### P1 - Major (Should fix)
- [x] None

#### P2 - Minor (Can defer)
- [ ] `MemoryDistiller.swift:526` - usage of `try!` for regex compilation. While safe for hardcoded strings, it's good practice to wrap in a `lazy` property or handle potential errors if patterns become dynamic.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

## Completion Status

- [x] Implementation complete
- [x] Code review passed (1 iteration)
- [x] PR merged: #144
- [x] Merged to main: 6890313
- [x] Date: 2026-02-16
