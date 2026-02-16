# MEM.18 - Distiller Quality & Deduplication

**Epic:** Memory System
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 3 days
**Dependencies:** MEM.08, MEM.09
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Improve the quality of memory entries produced by the distiller and strengthen deduplication so that MEMORY.md remains concise, high-signal, and useful. Currently, after ~57 sessions the file has grown to 258 lines with ~88% redundancy, test noise, and buried real data.

## 2. User Story

As a user, I want MEMORY.md to contain only meaningful, non-redundant information about me so that Ora's memory is useful rather than a wall of repeated noise.

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

Plus 3 orphaned `## Memory Update` sections (lines 6-26) from an older code path that don't correspond to any defined section.

### Root Causes (prioritized by impact)

**RC-1: Tool messages leak into the transcript.** `renderTranscript()` includes `.tool` role messages verbatim — the model sees `[ToolResult: test.create] Created (auditId=A96C...)` and faithfully extracts it as a fact. This single issue accounts for ~50% of all junk entries (audit IDs, tool names, "Created N items using X tool").

**RC-2: Distiller has no awareness of existing memory.** Each session is distilled in isolation. The model doesn't know "User's name is Benedict" was already extracted 3 sessions ago, so it extracts it again with slightly different wording. This is the primary driver of semantic duplicates.

**RC-3: No minimum session threshold.** 55/57 sessions follow the exact same test harness pattern: "Create something" → tool result → "Hello" → "Schedule a meeting" → "Test provider setup issue". These trivial/synthetic sessions should produce 0 entries, but each generates 5-10.

**RC-4: Prompt is too permissive.** The distiller prompt says "extract stable facts" but doesn't say what NOT to extract. The 7B model is eager to please and generates entries for everything, including interaction patterns ("User uses greeting phrases") and session mechanics ("Assistant confirmed completion").

**RC-5: Dedup is exact-match only.** `dedupFingerprint` normalizes whitespace/case and compares exact strings. "User prefers to initiate actions with 'create' commands" vs "User prefers to initiate actions via direct commands such as 'create'" are different strings but identical semantically.

**RC-6: Section misclassification.** Entries like "User consistently uses greeting phrases" appear under **People** instead of Preferences or nowhere. The model doesn't understand section semantics well enough. The prompt lacks section descriptions.

## 4. Scope

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

## 5. Architecture Alignment

- **Components:** `Ora/Memory/MemoryDistiller.swift`, `Ora/Memory/MemoryFileManager.swift`, `Ora/Resources/memory-distill-prompt.txt`
- **Existing utility:** `StringSimilarity.jaroWinkler()` in `Ora/Tools/Contacts/StringSimilarity.swift`
- **Concurrency:** No changes — all entry filtering happens synchronously during distillation

## 6. Implementation Plan

### 6.1 Strip Tool Messages from Transcript (RC-1 — highest impact)

In `MemoryDistiller.renderTranscript()`, filter out `.tool` role messages before rendering. The model doesn't need to see `[ToolResult: test.create] Created (auditId=...)` — it adds noise and causes the model to extract tool mechanics as "facts."

```swift
private func renderTranscript(_ messages: [Session.Message]) -> String {
    let filtered = messages.filter { $0.role != .tool }
    // ... existing rendering ...
}
```

This single change eliminates the source of ~50% of junk entries.

### 6.2 Feed Existing Memory as Context (RC-2 — second highest impact)

Before calling the LLM, read current MEMORY.md and inject it into the prompt:

```
Here is what Ora already remembers (MEMORY.md):
---
<existing MEMORY.md content, truncated to ~2000 chars>
---

Only extract NEW information not already captured above.
If the conversation adds nothing new, return empty memory_entries.
```

This lets the model do semantic dedup at generation time — far more powerful than post-hoc string matching. Truncate to avoid blowing the context window; prioritize Profile and Preferences sections (most likely to have duplicates).

### 6.3 Minimum Session Threshold (RC-3)

Skip distillation entirely for sessions that are too short to contain meaningful content:

- Fewer than 3 user messages, OR
- Total user content length < 50 characters

These sessions still get a summary file (for completeness) but produce 0 memory entries.

```swift
let userMessages = messages.filter { $0.role == .user }
let totalUserChars = userMessages.reduce(0) { $0 + $1.content.count }
if userMessages.count < 3 || totalUserChars < 50 {
    // Write summary only, skip memory entry extraction
}
```

### 6.4 Prompt Improvements (RC-4, RC-6)

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

### 6.5 Fuzzy Deduplication (RC-5)

In `MemoryFileManager.deduplicatedEntries()`, add a second pass after exact-match:

1. **Exact match** (existing): Skip if `dedupFingerprint` matches exactly
2. **Fuzzy match** (new): For each new entry, compare its content against all existing entries in the **same section** using Jaro-Winkler. Skip if similarity >= 0.85

Entries with a `normalized_key` bypass fuzzy dedup (they use key-based dedup only).

### 6.6 Entry Cap (safety net)

After parsing the model's output, truncate `memoryEntries` to a maximum of 8 entries. The model's ordering reflects priority, so keep the first N.

### 6.7 Low-Value Content Filter (safety net)

Post-parse filter in `DistillationEnvelope.toPayload()` that drops entries matching:

- Contains "audit ID" or "audit_id" or a UUID pattern (case-insensitive)
- Matches greeting patterns: "User greeted", "User said hello", "User consistently uses greeting"
- Pure tool mechanics: "Created N items using X tool"
- Too short to be meaningful: content length < 20 characters

### 6.8 Clean Up Orphaned Sections

The `## Memory Update` headings (lines 6-26 in current MEMORY.md) are from an older code path. The `ensureRequiredSections()` method in MemoryFileManager should strip unrecognized `##` sections, or at minimum the template should not include them. Add a migration step that removes these on next write.

### 6.9 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Resources/memory-distill-prompt.txt` | Rewrite with negative instructions, section descriptions, selectivity guidance |
| `Ora/Memory/MemoryDistiller.swift` | Strip `.tool` messages in `renderTranscript()`, inject existing MEMORY.md as context, add minimum session threshold, add entry cap + low-value filter |
| `Ora/Memory/MemoryFileManager.swift` | Add fuzzy dedup in `deduplicatedEntries()`, clean up orphaned sections |

### 6.10 Tests to Add

| Test File | Coverage |
|:----------|:---------|
| `OraTests/MemoryDistillerTests.swift` | Tool message stripping, minimum session threshold, entry cap, low-value filter, existing memory injection |
| `OraTests/MemoryUpdatePolicyTests.swift` | Fuzzy dedup with near-duplicate entries, orphaned section cleanup |

## 7. Acceptance Criteria

- [ ] AC-1: `.tool` role messages are excluded from the transcript sent to the distiller
- [ ] AC-2: Existing MEMORY.md content is included in the distiller prompt as context
- [ ] AC-3: Sessions with < 3 user messages or < 50 chars user content produce 0 memory entries
- [ ] AC-4: Distiller prompt includes explicit negative instructions and section descriptions
- [ ] AC-5: Near-duplicate entries (Jaro-Winkler >= 0.85 within same section) are rejected
- [ ] AC-6: Entries containing audit IDs, UUIDs, or trivial greetings are filtered out
- [ ] AC-7: Maximum 8 memory entries per distillation
- [ ] AC-8: A session with real content (name, preferences, decisions) still produces correct entries in the right sections
- [ ] AC-9: Manual E2E test starts with a clean/reset memory folder (delete existing MEMORY.md + Summaries before testing)

## 8. Verification Plan

### Automated Tests

- [ ] Unit test: `renderTranscript` excludes `.tool` messages
- [ ] Unit test: sessions below minimum threshold produce 0 memory entries (summary still written)
- [ ] Unit test: fuzzy dedup rejects "User prefers X" vs "User prefers X via Y" (same section, JW >= 0.85)
- [ ] Unit test: fuzzy dedup allows genuinely different entries in the same section
- [ ] Unit test: low-value filter drops entries with audit IDs / UUIDs
- [ ] Unit test: low-value filter drops greeting-only entries
- [ ] Unit test: entry cap limits output to 8
- [ ] Unit test: real content passes through all filters unchanged
- [ ] Unit test: existing MEMORY.md content is present in the LLM prompt

### Manual Tests

- [ ] Reset memory folder, run Ora, have a trivial conversation ("Hello", "Hi"), verify MEMORY.md gets 0 new entries
- [ ] Run Ora, share real info ("My name is Alex, I prefer evening workouts"), verify entries appear in correct sections
- [ ] Run 5+ sessions, inspect MEMORY.md — verify no excessive duplication and correct section assignment
- [ ] Run a session that uses tools (create event, search contacts), verify tool mechanics don't appear in MEMORY.md

## 9. Performance / Reliability Considerations

- Stripping tool messages reduces transcript size → faster LLM inference
- Injecting existing MEMORY.md adds ~2KB to the prompt — well within Qwen 2.5's context window
- Fuzzy dedup adds O(n*m) Jaro-Winkler comparisons per section. With typical section sizes of 5-20 (post-fix), this is negligible
- Minimum session threshold eliminates ~90% of current distillation calls (most sessions are trivial test sessions)

## 10. Risks & Mitigations

- **Risk:** Overly aggressive filtering drops valid entries → **Mitigation:** Tune thresholds conservatively (JW 0.85, 8-entry cap, 20-char minimum). Entries with `normalized_key` bypass fuzzy dedup.
- **Risk:** Injecting existing memory makes the prompt too long → **Mitigation:** Truncate to ~2000 chars, prioritize Profile + Preferences sections.
- **Risk:** Minimum session threshold skips a short but meaningful session → **Mitigation:** 3 messages / 50 chars is very low — "My name is Alex" alone is 15 chars across 1 message. A real preference-sharing session will exceed this easily.
- **Risk:** Prompt changes cause model to return invalid JSON → **Mitigation:** Only add instructional text, don't change the schema. Existing retry logic handles parse failures.

## 11. Open Questions

- Should we provide a one-time "compact MEMORY.md" utility that deduplicates the existing file? (Recommend as a follow-up story — worth doing but separate scope.)
- What Jaro-Winkler threshold works best empirically? Start at 0.85 and tune based on testing.
- Should the existing memory injection be the full file or just section headings + entry count? Full file gives better semantic dedup; summary is cheaper on tokens.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
