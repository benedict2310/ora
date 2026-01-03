# S.05 - Embedding-Based Skill Retrieval

**Epic:** Skills
**Status:** Future
**Priority:** P3 (Low)
**Estimated Effort:** 4 days
**Dependencies:** S.01 (Skills Runtime)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Replace or augment the metadata-based skill listing with embedding-based semantic retrieval, enabling more accurate skill activation when the user's intent doesn't exactly match skill keywords.

## 2. User Story

As a user, I want Ora to find the right skill even when I phrase my request differently than the skill description, so that I don't have to memorize exact skill names.

## 3. Scope

### In Scope

- On-device embedding model for skill descriptions
- Semantic similarity search for skill activation
- Hybrid retrieval (keywords + embeddings)
- Skill embedding precomputation at index time
- Query embedding at inference time

### Out of Scope

- Cloud-based embedding services
- Training custom embedding models
- Embedding skill content (just metadata for now)
- Multi-modal embeddings (just text)

## 4. Architecture Alignment

### Embedding Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                 Embedding-Based Retrieval                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Indexing (startup):                                         │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐      │
│  │  Skill      │───►│  Embedding  │───►│  Vector     │      │
│  │  Metadata   │    │  Model      │    │  Index      │      │
│  └─────────────┘    └─────────────┘    └─────────────┘      │
│                                                              │
│  Query (runtime):                                            │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐      │
│  │  User       │───►│  Embedding  │───►│  Similarity │      │
│  │  Query      │    │  Model      │    │  Search     │      │
│  └─────────────┘    └─────────────┘    └─────────────┘      │
│                             │                  │             │
│                             ▼                  ▼             │
│                      ┌─────────────────────────────┐        │
│                      │  Ranked Skill Candidates    │        │
│                      └─────────────────────────────┘        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Model Options

| Model | Size | Quality | Notes |
|:------|:-----|:--------|:------|
| all-MiniLM-L6-v2 | ~80MB | Good | Fast, widely used |
| bge-small-en-v1.5 | ~130MB | Better | Good for retrieval |
| nomic-embed-text | ~270MB | Best | MLX-compatible |

### Integration Points

- `SkillStore.rebuildIndex()` — compute embeddings for each skill
- `skills.list` — optionally include similarity scores
- System prompt — rank skills by relevance instead of alphabetically
- New tool: `skills.find(query)` — semantic search

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

| File | Purpose |
|:-----|:--------|
| `Ora/Skills/SkillEmbedder.swift` | Embedding model wrapper |
| `Ora/Skills/SkillVectorIndex.swift` | Vector similarity search |
| `Ora/Tools/Skills/SkillsFindTool.swift` | Semantic search tool |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Skills/SkillStore.swift` | Add embedding computation at index time |
| `Ora/LLM/SystemPromptBuilder.swift` | Optionally rank skills by query relevance |
| `project.yml` | Add embedding model dependency |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `OraTests/Skills/SkillEmbedderTests.swift` | Embedding generation, caching |
| `OraTests/Skills/SkillVectorIndexTests.swift` | Similarity search, ranking |

### 5.4 Dependencies/Config

- Embedding model (MLX-compatible)
- Vector similarity library (or custom cosine similarity)

## 6. Acceptance Criteria

- [ ] AC-1: Embedding model loaded at app startup (lazy, on first use)
- [ ] AC-2: Skill descriptions embedded and cached
- [ ] AC-3: `skills.find(query)` returns semantically similar skills
- [ ] AC-4: Results include similarity scores
- [ ] AC-5: Fallback to keyword matching if embedding fails
- [ ] AC-6: Embedding computation doesn't block UI
- [ ] AC-7: Cache embeddings to avoid recomputation

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for embedding generation
- [ ] Unit tests for vector similarity search
- [ ] Unit tests for caching behavior
- [ ] Integration test for semantic search flow

### Manual Tests

- [ ] Search for skill using synonyms, verify correct skill found
- [ ] Verify embedding computation happens in background
- [ ] Test fallback when embedding model unavailable

## 8. Performance / Reliability Considerations

- Embedding computation: background thread, cached
- Model loading: lazy, unload after idle period
- Memory: ~80-270MB depending on model choice
- Similarity search: O(n) for n skills, fast for typical use

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| Model size increases app size | Lazy download, optional feature |
| Embedding latency | Precompute at index time, cache |
| Quality issues | Hybrid approach (embeddings + keywords) |
| Memory usage | Load model on demand, unload when idle |

## 10. Open Questions

- Which embedding model to use? (Size vs. quality tradeoff)
- Embed just `description` or also `name`?
- Threshold for "relevant" skill (similarity cutoff)?
- Should this replace or augment `skills.list`?
- How to handle embedding model download?

---

## Notes

This is an enhancement for scale. With few skills (less than 20), keyword matching in skill descriptions is likely sufficient. Embeddings become valuable when:

- Many skills installed
- Skills have similar names but different purposes
- User queries are semantically different from skill descriptions

Consider starting with a simpler heuristic:
- TF-IDF or BM25 on skill descriptions
- Only add embeddings if retrieval quality is a problem

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
