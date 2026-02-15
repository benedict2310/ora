# MEM.13 - Transcript Fallback Retrieval

**Epic:** Memory System
**Status:** Not Started
**Priority:** P2 (Medium)
**Estimated Effort:** 1.5 days
**Dependencies:** MEM.11
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

When memory summaries and MEMORY.md don't contain sufficient detail, fall back to searching raw transcript chunks for detailed rationale, exact quotes, or specific conversation context. This handles queries like "why did we choose X?" that require granular detail not captured in summaries.

## 2. User Story

As a user, I want Ora to find specific details from past conversations even if they weren't captured in the summary, so that I can recall exact reasoning or decisions.

## 3. Scope

### In Scope

- Chunk persisted transcripts by turns (keep Q/A pairs together to preserve context)
- Index transcript chunks in FTS5 (or extend existing index with a transcript table)
- Only search transcripts for:
  - Sessions identified by summary hits (follow the breadcrumb)
  - Last N sessions if no summary exists yet
- Implement as a fallback: only invoked when memory/summary results score below a threshold

### Out of Scope

- Embedding transcript chunks (could be added on top of MEM.12)
- Cross-session transcript analysis
- Transcript export or user-facing transcript UI

## 4. Architecture Alignment

- **Component:** Extend `Ora/Memory/MemoryIndex.swift`
- **Data source:** `Session.messages` from SwiftData (read on MainActor, copy as value types)
- **Chunking strategy:** Group by Q/A turn pairs (user message + assistant response = 1 chunk)
- **Index scope:** Bounded — only index sessions referenced by summary hits or recent N sessions

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/TranscriptChunker.swift` — Chunk transcript into Q/A pairs

### 5.2 Files to Modify

- `Ora/Memory/MemoryIndex.swift` — Add transcript table, fallback search method
- `Ora/Orchestration/AgentLoop.swift` — Chain fallback after primary retrieval if results insufficient

### 5.3 Tests to Add

- `OraTests/TranscriptChunkerTests.swift` — Test chunking logic with various conversation patterns
- `OraTests/TranscriptRetrievalTests.swift` — Test fallback search and session scoping

### 5.4 Dependencies/Config

- None

## 6. Acceptance Criteria

- [ ] AC-1: Transcripts are chunked by Q/A turn pairs
- [ ] AC-2: Transcript search only runs as fallback when summary/memory results are insufficient
- [ ] AC-3: Transcript search is scoped to relevant sessions (identified by summary hits or recent N)
- [ ] AC-4: Queries like "why did we choose X" can retrieve detailed rationale from transcript
- [ ] AC-5: Transcript chunks include session ID and turn number for traceability

## 7. Verification Plan

### Automated Tests

- [ ] Unit test: chunk a sample transcript, verify Q/A pairs are grouped correctly
- [ ] Unit test: search transcript for known content, verify result
- [ ] Unit test: fallback only triggers when primary results are below threshold

### Manual Tests

- [ ] Have a detailed conversation, then ask about specific reasoning — verify transcript is consulted

## 8. Performance / Reliability Considerations

- Transcript indexing should be lazy (only index when needed, not eagerly on every session)
- Transcript search is bounded by session scope — never searches all history
- Large transcripts should be paginated/limited to prevent memory issues

## 9. Risks & Mitigations

- **Risk:** Transcript search returns too much context → **Mitigation:** Limit to top 3 chunks; summarize if needed
- **Risk:** Old transcripts grow stale/irrelevant → **Mitigation:** Prefer recent sessions; eventually age out old transcripts from index

## 10. Open Questions

- What's the optimal chunk size for Q/A pairs? Single turn or multi-turn context window?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
