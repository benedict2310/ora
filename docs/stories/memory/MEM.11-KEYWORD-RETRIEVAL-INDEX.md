# MEM.11 - Keyword Retrieval Index

**Epic:** Memory System
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 2 days
**Dependencies:** MEM.06, MEM.10
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Build a keyword-based retrieval index over MEMORY.md and session summaries so that Ora can find relevant memory blocks when triggered. Uses SQLite FTS5 for fast full-text search, separate from the SwiftData store.

## 2. User Story

As a user, I want Ora to find relevant past conversations and memories when I ask about something we discussed before.

## 3. Scope

### In Scope

- Create a dedicated SQLite FTS5 index (separate database from SwiftData)
- Index:
  - `MEMORY.md` entries (chunked by section/entry)
  - `Summaries/*.md` (chunked by section)
- Store chunk metadata: document type, session ID, section name, last modified
- Provide `MemoryIndex.search(query:limit:)` → `[MemoryChunk]`
- Rebuild index on launch and after distillation runs
- Inject top-scoring chunks into LLM prompt as context

### Out of Scope

- Embedding-based retrieval (MEM.12)
- Transcript-level search (MEM.13)
- Hybrid scoring (MEM.12)

## 4. Architecture Alignment

- **Component:** New `Ora/Memory/MemoryIndex.swift`
- **Storage:** SQLite FTS5 in `~/Documents/Ora/Memory/.index.sqlite` (hidden file alongside user files)
- **Concurrency:** Index operations on a dedicated serial queue/actor to avoid contention
- **Integration:** Called from `AgentLoop` when `MemoryTriggerDetector` fires, results injected into `ConversationManager` context

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/MemoryIndex.swift` — FTS5 index creation, ingestion, search
- `Ora/Memory/MemoryChunk.swift` — Chunk model (content, metadata, score)

### 5.2 Files to Modify

- `Ora/Orchestration/AgentLoop.swift` — After trigger detection, search index and inject results into prompt
- `Ora/LLM/ConversationManager.swift` — Accept optional memory context for injection
- `Ora/Memory/MemoryDistiller.swift` — Trigger re-index after distillation

### 5.3 Tests to Add

- `OraTests/MemoryIndexTests.swift` — Test indexing, search ranking, chunk metadata

### 5.4 Dependencies/Config

- SQLite FTS5 (available in macOS system SQLite)

## 6. Acceptance Criteria

- [ ] AC-1: MEMORY.md and summary files are indexed into FTS5 on launch
- [ ] AC-2: `search(query:limit:)` returns relevant chunks ranked by BM25 score
- [ ] AC-3: Chunk metadata includes document type, session ID, and section
- [ ] AC-4: Index rebuilds after distillation runs
- [ ] AC-5: Top 3–7 chunks are injected into LLM prompt when retrieval triggers
- [ ] AC-6: If top score is below threshold, no context is injected (precision-biased)

## 7. Verification Plan

### Automated Tests

- [ ] Unit test: index sample MEMORY.md, search for known term, verify result
- [ ] Unit test: search with no matches returns empty results
- [ ] Unit test: verify BM25 ranking (more relevant chunks score higher)

### Manual Tests

- [ ] Add entries to MEMORY.md, ask Ora about them — verify retrieved in response

## 8. Performance / Reliability Considerations

- FTS5 queries are fast (< 10ms for typical index sizes)
- Index rebuild should be incremental where possible (check file modification dates)
- Index is derivative data — can be safely deleted and rebuilt

## 9. Risks & Mitigations

- **Risk:** Index grows large with many sessions → **Mitigation:** Summaries are compact; only index summaries, not full transcripts (MEM.13 adds transcript fallback)
- **Risk:** FTS5 tokenization misses multi-word entities → **Mitigation:** Use phrase matching and trigram tokenizer if needed

## 10. Open Questions

- Should the index use the default FTS5 tokenizer or a custom one optimized for conversational text?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
