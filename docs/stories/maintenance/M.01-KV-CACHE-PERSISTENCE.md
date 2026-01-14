# M.01 - KV Cache Persistence for Multi-Turn Conversations

**Status:** Complete
**Priority:** P0 - Critical
**Epic:** Performance Optimization
**Dependencies:** None
**Target:** Ora 1.1

---

## 1. Objective

Implement persistent KV (key-value) cache reuse across conversation turns to dramatically reduce latency for follow-up messages. Currently, each LLM generation reprocesses the entire conversation history from scratch.

---

## 2. User Story

As a user having a multi-turn conversation with Ora, I want follow-up responses to be significantly faster than the first response, so that the conversation feels natural and responsive.

---

## 3. Scope

### In Scope
- Create and persist KV cache across conversation turns within a session
- Reuse cache in `LLMService.runGeneration()` for subsequent turns
- Clear KV cache when session ends or conversation is reset
- Memory monitoring to track KV cache size

### Out of Scope
- KV cache quantization (future optimization)
- KV cache pruning for very long conversations (future story)
- Persisting KV cache to disk between app launches

---

## 4. Architecture Alignment

MLX Swift provides `TokenIterator` with an optional cache parameter:
```swift
public init(
    input: LMInput, 
    model: any LanguageModel, 
    cache: [KVCache]? = nil,  // Pass existing cache here
    parameters: GenerateParameters
) throws
```

The `ChatSession` class from MLX demonstrates the pattern:
```swift
if cache.isEmpty {
    cache = context.model.newCache(parameters: generateParameters)
}
// Then reuse `cache` in subsequent generations
```

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- None required

### 5.2 Files to Modify
- `Ora/LLM/Types.swift` - Add `clearCache()` to protocol
- `Ora/LLM/LLMService.swift` - Add KV cache storage and reuse logic
- `Ora/LLM/ConversationManager.swift` - Clear cache on new conversation
- `Ora/Orchestration/AgentLoop.swift` - Clear cache on session end

---

## 6. Acceptance Criteria

- [x] KV cache is created on first generation of a session
- [x] Subsequent generations in same session reuse the cache
- [ ] Time-to-first-token for turn 2+ is measurably faster than turn 1 (target: 50%+ reduction) - Manual verification
- [x] KV cache is cleared when `AgentLoop.endSession()` is called
- [x] KV cache is cleared when `ConversationManager.startConversation()` is called
- [x] KV cache is cleared when `LLMService.unload()` is called
- [ ] Memory usage does not grow unboundedly across sessions - Manual verification
- [ ] No regression in first-turn latency - Manual verification
- [x] Unit tests pass for cache lifecycle

---

## 7. Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-14
**Iterations:** 2

### Issues Found and Resolved

#### P0 - Critical (Fixed)
- **Data Race on `kvCache`**: Wrapped `clearCache()` and `unload()` mutations in `MLXMetalGate.shared.withExclusiveAccess`

#### P2 - Minor (Deferred)
- `totalTokens` hardcoded to 0 in completion event
- String-based stop token checking is fragile

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## 8. Implementation Summary

**Date:** 2026-01-14
**Branch:** `feat/M.01-kv-cache-persistence`
**Commits:** 4

### Files Changed

| File | Change |
|------|--------|
| `Ora/LLM/Types.swift` | Added `clearCache()` method to `LLMServicing` protocol |
| `Ora/LLM/LLMService.swift` | Added `kvCache` property, migrated to `TokenIterator` API, implemented cache lifecycle |
| `Ora/LLM/ConversationManager.swift` | Added cache clearing on new conversation start |
| `Ora/Orchestration/AgentLoop.swift` | Added cache clearing on session end |
| `OraTests/LLM/LLMServiceTests.swift` | Added KV cache lifecycle tests |

### Key Implementation Notes

1. **nonisolated(unsafe)**: Used for `kvCache` property because `KVCache` protocol is not `Sendable`. Thread safety guaranteed by `MLXMetalGate`.

2. **Modern MLX API**: Migrated from deprecated `MLXLMCommon.generate(promptTokens:...)` to `TokenIterator` + `MLXLMCommon.generate(input:context:iterator:)`.

---

## Completion Status

- [x] Implementation complete
- [x] Code review passed (2 iterations)
- [x] PR merged: https://github.com/benedict2310/ora/pull/67
- [x] Merged to main: a43ee40
- [x] Date: 2026-01-14
