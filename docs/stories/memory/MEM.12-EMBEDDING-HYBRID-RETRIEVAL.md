# MEM.12 - Embedding Hybrid Retrieval

**Epic:** Memory System
**Status:** Not Started
**Priority:** P2 (Medium)
**Estimated Effort:** 3 days
**Dependencies:** MEM.11
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Enhance retrieval quality by adding local embeddings for semantic search and combining with keyword-based BM25 scores. Hybrid scoring captures both exact matches and semantic similarity, improving recall for paraphrased or conceptually related queries.

## 2. User Story

As a user, I want Ora to understand what I mean even when I don't use the exact same words as before, so that retrieval feels natural and accurate.

## 3. Scope

### In Scope

- Select and integrate a local embedding model (small, fast, Metal-accelerated)
- Embed MEMORY.md chunks and summary chunks into vector store
- Implement hybrid scoring: `0.7 * cosine_similarity + 0.3 * bm25_score + recency_boost`
- Precision-biased thresholding: if top score < threshold, inject nothing
- Limit injected snippets to top 3–7 results
- Store embeddings alongside FTS5 index

### Out of Scope

- Cloud-based embeddings (local-only)
- Fine-tuning embedding model
- Transcript-level embedding (MEM.13)

## 4. Architecture Alignment

- **Component:** Extend `Ora/Memory/MemoryIndex.swift`
- **Embedding model:** Dedicated small model (e.g., `nomic-embed-text` or `bge-small-en-v1.5` via MLX). Separate from Qwen generation model.
- **GPU memory:** Must respect GPU cache limits per CLAUDE.md guidelines. Set cache limit on model load, clear cache after embedding batch.
- **Storage:** Embeddings stored in SQLite (BLOB column) alongside FTS5 index

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

- `Ora/Memory/EmbeddingService.swift` — Load embedding model, encode text to vectors
- `Ora/Memory/HybridScorer.swift` — Combine cosine + BM25 + recency scores

### 5.2 Files to Modify

- `Ora/Memory/MemoryIndex.swift` — Add embedding storage and hybrid search
- `Ora/Memory/MemoryChunk.swift` — Add embedding vector field

### 5.3 Tests to Add

- `OraTests/EmbeddingServiceTests.swift` — Test embedding generation, vector dimensions
- `OraTests/HybridScorerTests.swift` — Test score combination and thresholding

### 5.4 Dependencies/Config

- Embedding model download (small, ~100MB)
- `project.yml` — May need MLX dependency adjustment

## 6. Acceptance Criteria

- [ ] AC-1: Local embedding model generates vectors for memory chunks
- [ ] AC-2: Hybrid score combines cosine similarity (0.7), BM25 (0.3), and recency boost
- [ ] AC-3: Retrieval quality improves vs keyword-only for paraphrased queries
- [ ] AC-4: If top hybrid score < threshold, no context is injected
- [ ] AC-5: Injected snippets limited to 3–7 results
- [ ] AC-6: GPU cache cleared after embedding batch

## 7. Verification Plan

### Automated Tests

- [ ] Unit test: embed sample text, verify vector dimensions and non-zero values
- [ ] Unit test: hybrid scorer returns correct ranking for known inputs
- [ ] Unit test: threshold filtering prevents low-quality results from injection

### Manual Tests

- [ ] Store a preference in MEMORY.md ("I like spicy food"), ask "what kind of food do I enjoy?" — verify retrieved

## 8. Performance / Reliability Considerations

- Embedding model load time adds to launch (or lazy-load on first retrieval trigger)
- Batch embedding on distillation, not per-query (vectors are stored)
- GPU memory: embedding model is small (~100MB), but must share GPU with LLM/TTS

## 9. Risks & Mitigations

- **Risk:** Embedding model too large for memory-constrained systems → **Mitigation:** Use smallest viable model; fallback to keyword-only (MEM.11)
- **Risk:** Hybrid scoring parameters need tuning → **Mitigation:** Start with research defaults (0.7/0.3), tune based on retrieval quality tests

## 10. Open Questions

- Which embedding model provides the best quality/size tradeoff for on-device use?
- Should embeddings be generated lazily (on first query) or eagerly (on distillation)?

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
