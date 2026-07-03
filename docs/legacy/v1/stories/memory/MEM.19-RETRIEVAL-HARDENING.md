# MEM.19 - Memory Retrieval Hardening

**Epic:** Memory System
**Status:** Not Started
**Priority:** P1 (High)
**Estimated Effort:** 3 days
**Dependencies:** MEM.12, MEM.13
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Fix two concrete defects in the memory retrieval pipeline that were identified during a
structured evaluation of the distiller-vs-vectorization trade-offs
(see `docs/investigations/memory-retrieval-evaluation-2026-02-20.md`):

1. **Unbounded semantic candidate fetch** — `fetchSemanticCandidates` issues a SQL query
   with no `LIMIT`, fetching every embedding blob in the index on every search call.
   As the memory index grows this degrades linearly and will become noticeable at scale.

2. **BM25-only transcript fallback** — `searchTranscriptFallback` inserts transcript chunks
   into a temporary FTS5 table and scores them with BM25 only. Semantically related but
   lexically different queries ("what did we agree about the project?" vs a session that
   said "we settled on the approach") get zero recall. The primary memory search already
   has full hybrid scoring (0.7 cosine + 0.3 BM25); the fallback should too.

Both fixes are purely additive (no schema incompatibility, no API surface changes) and stay
entirely within `Ora/Memory/`.

---

## 2. User Story

As a user, I want Ora to recall relevant context from past conversations even when I phrase
my question differently from how things were originally said, without the app slowing down
after months of use.

---

## 3. Scope

### In Scope

- Cap `fetchSemanticCandidates` with a `LIMIT` ordered by recency (`last_modified DESC`)
  so the semantic candidate set stays bounded regardless of index growth.
- Add a `transcript_chunk_embeddings` table (keyed by `session_id + turn_number`) to the
  SQLite schema for persisting transcript chunk embeddings between calls.
- Embed transcript chunks during `replaceTranscriptIndexContents` and upsert into the new
  table (batch of up to 16, same pattern as `embedChunks` in the primary path).
- Replace `searchTranscriptIndex` (BM25-only) with `searchTranscriptIndexHybrid` that
  merges BM25 candidates with embeddings from `transcript_chunk_embeddings` and runs them
  through the existing `HybridScorer`.
- Fall back to BM25-only if the embedding service is unavailable (same pattern as
  `searchIndexHybrid` → `searchIndexKeywordOnly`).
- Pass `queryEmbedding` down from `searchTranscriptFallback` into the hybrid scorer.
- Unit tests for both fixes.

### Out of Scope

- Replacing the distiller with a lighter extraction approach (MEM.18 addressed quality;
  prompt brittleness has not been observed in production since that fix).
- Approximate nearest-neighbour (ANN) indexing (overkill at current scale; the recency-
  bounded LIMIT solves the immediate problem).
- Persisting transcript chunk embeddings across full index rebuilds (the table is rebuilt
  lazily on fallback calls, which is the same pattern as the existing FTS5 transcript table).
- Changes to `HybridScorer`, `EmbeddingService`, or `TranscriptChunker`.
- UI or Preferences changes.

---

## 4. Architecture Alignment

- **Components touched:** `Ora/Memory/HybridSearcher.swift`,
  `Ora/Memory/TranscriptIndexer.swift`, `Ora/Memory/MemoryIndexSchema.swift`,
  `Ora/Memory/MemoryIndex.swift`
- **Concurrency:** All changes are within the `MemoryIndex` actor — no threading changes
  required. `EmbeddingService.embed(texts:)` is already called from within the actor on the
  primary path.
- **GPU memory:** Transcript chunk embedding batch (≤16 chunks per call) is the same size
  as the existing primary embed batch. `GPU.clearCache()` is already called after each
  distillation run; no new GPU pressure is introduced.
- **No guardrails / audit logging needed** — this is a pure read-path change.

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

None.

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Memory/MemoryIndexSchema.swift` | Add `CREATE TABLE IF NOT EXISTS transcript_chunk_embeddings (session_id TEXT NOT NULL, turn_number INTEGER NOT NULL, embedding BLOB NOT NULL, PRIMARY KEY (session_id, turn_number));` to `ensureSchema`. |
| `Ora/Memory/HybridSearcher.swift` | (1) Add `ORDER BY c.last_modified DESC LIMIT ?` to `fetchSemanticCandidates`, binding a constant cap (e.g. `512`). (2) Add `searchTranscriptIndexHybrid` method mirroring `searchIndexHybrid` but querying `transcript_chunks` + `transcript_chunk_embeddings`. |
| `Ora/Memory/TranscriptIndexer.swift` | In `replaceTranscriptIndexContents`, after inserting FTS5 rows, batch-embed the chunks via `embeddingService` and upsert into `transcript_chunk_embeddings`. |
| `Ora/Memory/MemoryIndex.swift` | In `searchTranscriptFallback`, embed the query and pass `queryEmbedding` to the new hybrid method; keep BM25-only fallback if embedding fails. |

### 5.3 Tests to Add

| Test File | Coverage |
|:----------|:---------|
| `OraTests/MemoryIndexHybridSearchTests.swift` | `fetchSemanticCandidates` with a mock DB containing >512 rows respects the LIMIT. |
| `OraTests/MemoryIndexTranscriptTests.swift` | `searchTranscriptFallback` with a mock `EmbeddingService` returns hybrid-scored results; degrades to BM25 when embedding service throws. |

### 5.4 Semantic Candidate Cap — Detail

Replace the current unbounded SQL in `fetchSemanticCandidates`:

```sql
-- BEFORE (no limit)
SELECT e.chunk_rowid, c.last_modified, 0.0 AS bm25_score, e.embedding
FROM memory_chunk_embeddings e
JOIN memory_chunks c ON c.rowid = e.chunk_rowid
WHERE e.embedding IS NOT NULL;

-- AFTER (recency-bounded)
SELECT e.chunk_rowid, c.last_modified, 0.0 AS bm25_score, e.embedding
FROM memory_chunk_embeddings e
JOIN memory_chunks c ON c.rowid = e.chunk_rowid
WHERE e.embedding IS NOT NULL
ORDER BY c.last_modified DESC
LIMIT ?;   -- bind to constant (e.g. 512)
```

Rationale for recency sort: `HybridScorer` already applies a recency boost
(`maxRecencyBoost = 0.08`, half-life 30 days), so preferring newer chunks in the candidate
set is consistent with the scoring policy. Chunks older than ~6 months get near-zero recency
boost and are unlikely to rank above the LIMIT threshold.

512 is a conservative cap: the current MEMORY.md index has O(dozens) of chunks; even a
heavy multi-year user is unlikely to exceed a few hundred distilled bullets + summary
sections. The cap is a constant, easy to tune later.

### 5.5 Transcript Hybrid Search — Detail

Schema addition in `ensureSchema`:

```sql
CREATE TABLE IF NOT EXISTS transcript_chunk_embeddings (
    session_id   TEXT    NOT NULL,
    turn_number  INTEGER NOT NULL,
    embedding    BLOB    NOT NULL,
    PRIMARY KEY (session_id, turn_number)
);
```

In `replaceTranscriptIndexContents`, after the existing FTS5 insert loop:

```swift
// Embed and upsert
let texts = chunks.map { $0.content }
if let embeddings = try? await embeddingService.embed(texts: texts) {
    // upsert into transcript_chunk_embeddings
    for (chunk, embedding) in zip(chunks, embeddings) {
        // INSERT OR REPLACE INTO transcript_chunk_embeddings ...
    }
}
GPU.clearCache()
```

`searchTranscriptFallback` then:
1. Calls `embeddingService.embed(text: normalizedQuery)` to get the query vector.
2. If successful, calls `searchTranscriptIndexHybrid(expression:queryEmbedding:limit:database:)`.
3. If embedding fails, falls back to the existing `searchTranscriptIndex` (BM25-only).

`searchTranscriptIndexHybrid` mirrors `searchIndexHybrid`:
- Fetch keyword candidates from `transcript_chunks` FTS5.
- Fetch embedding candidates from `transcript_chunk_embeddings` (bounded by `LIMIT`).
- Merge by `(session_id, turn_number)` key.
- Run through `hybridScorer.rank(queryEmbedding:candidates:)`.
- Apply `minimumHybridScore` threshold.

---

## 6. Acceptance Criteria

- [ ] AC-1: `fetchSemanticCandidates` SQL includes `ORDER BY last_modified DESC LIMIT N`
  with a compile-time constant N ≥ 128.
- [ ] AC-2: A memory index with more rows than the cap returns results in ≤ the capped count
  from the semantic path; the hybrid scorer still runs correctly on the bounded set.
- [ ] AC-3: `transcript_chunk_embeddings` table is created during `ensureSchema` without
  dropping existing data.
- [ ] AC-4: After a `searchTranscriptFallback` call, `transcript_chunk_embeddings` contains
  rows for every chunk that was inserted into `transcript_chunks` in that call.
- [ ] AC-5: `searchTranscriptFallback` returns hybrid-scored `MemoryChunk` values when the
  embedding service is available.
- [ ] AC-6: `searchTranscriptFallback` returns BM25-only `MemoryChunk` values (non-empty,
  same as today) when the embedding service throws.
- [ ] AC-7: All existing `MemoryIndex` tests continue to pass.
- [ ] AC-8: `./build.sh test` passes with no regressions.

---

## 7. Verification Plan

### Automated Tests

- [ ] Unit: `fetchSemanticCandidates` respects LIMIT with an over-full mock database.
- [ ] Unit: `searchTranscriptFallback` with mock `EmbeddingService` returning fixed vectors
  returns results with `.score` values in [0, 1] and the highest-scoring chunk corresponds
  to the most semantically similar turn.
- [ ] Unit: `searchTranscriptFallback` with a throwing mock `EmbeddingService` returns
  BM25-scored results (same as the pre-existing keyword-only path).
- [ ] Unit: `ensureSchema` is idempotent — calling it twice on an existing DB does not
  error and does not lose rows.

### Manual Tests

- [ ] Run Ora, have several conversations, then ask "what did we agree about [topic]" using
  different words than the original exchange — verify Ora recalls the context.
- [ ] Inspect `~/.ora/memory/.index.sqlite` after a fallback-triggering query:
  `sqlite3 ~/.ora/memory/.index.sqlite "SELECT count(*) FROM transcript_chunk_embeddings;"`
  should be > 0.

---

## 8. Performance / Reliability Considerations

- The semantic candidate cap (512) is O(N) bytes in memory per search call
  (N × 384 floats × 4 bytes = up to ~750 KB for 512 chunks). This is well within the
  existing memory envelope; the primary path already does this, just unboundedly.
- Transcript embedding on fallback adds one BGE-small inference call per fallback invocation
  (batch of up to ~30 turns). At ~5ms/batch on M-series this is imperceptible.
- The `transcript_chunk_embeddings` table grows with each fallback call. A `DELETE WHERE
  session_id NOT IN (...)` cleanup pass on stale session IDs could be added later, but is
  not required for correctness.

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| Recency-sort cap excludes an older but highly relevant chunk | Cap is 512 — in practice the index won't approach this for years of personal use. Re-evaluate if the product evolves to shared/team use cases. |
| BGE-small not loaded when transcript fallback fires | Already handled: embedding failure → BM25 fallback, which is the current production behaviour. No regression. |
| `transcript_chunk_embeddings` table migration on existing installs | `CREATE TABLE IF NOT EXISTS` is safe on existing databases; no migration required. |

---

## 10. Open Questions

- Should the semantic candidate cap be a named constant in `MemoryIndex` (e.g.
  `static let maximumSemanticCandidates = 512`) or a configuration property? A named
  constant is simpler and sufficient.
- Should `transcript_chunk_embeddings` rows be cleaned up when old sessions are deleted
  from SwiftData? Out of scope for this story; the table is small and SQLite handles
  abandoned rows gracefully.

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
