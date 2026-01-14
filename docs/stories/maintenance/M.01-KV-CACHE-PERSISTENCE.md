# M.01 - KV Cache Persistence for Multi-Turn Conversations

**Status:** Open
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

**From Research:**
> MLX's LLM API supports persistent key/value caches to speed up multi-turn chats. In Swift, you can create a cache once and reuse it across generations. The pattern is to initialize a cache via the model/context and supply it when generating tokens so the model doesn't recompute the entire history each time.

**Code Pattern (from Apple WWDC sample):**
```swift
try await modelContainer.perform { context in
    let params = GenerateParameters() 
    let cache = context.model.newCache(parameters: params)  // create KV cache
    
    // First user prompt
    let input1 = try await context.processor.prepare(input: UserInput(prompt: firstUserPrompt))
    let iter1 = try TokenIterator(input: input1, model: context.model, cache: cache, parameters: params)
    for await token in generate(input: input1, context: context, iterator: iter1) {
        // stream tokens
    }
    
    // Second user prompt - reuse same cache
    let input2 = try await context.processor.prepare(input: UserInput(prompt: followUpPrompt))
    let iter2 = try TokenIterator(input: input2, model: context.model, cache: cache, parameters: params)
    for await token in generate(input: input2, context: context, iterator: iter2) {
        // stream tokens - faster because history is cached
    }
}
```

**Memory Impact:**
- KV cache grows with conversation length (~hundreds of MB for long chats)
- Still more efficient than re-feeding full history each turn
- Should clear cache when conversation ends to reclaim memory

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- None required

### 5.2 Files to Modify
- `Ora/LLM/LLMService.swift` - Add KV cache storage and reuse logic
- `Ora/LLM/ConversationManager.swift` - Coordinate cache lifecycle with conversation state
- `Ora/Orchestration/AgentLoop.swift` - Clear cache on session end

### 5.3 Tests to Add
- `OraTests/LLM/LLMServiceTests.swift` - Test cache reuse behavior
- `OraTests/LLM/KVCacheTests.swift` - Test cache lifecycle (create, reuse, clear)

---

## 6. Acceptance Criteria

- [ ] KV cache is created on first generation of a session
- [ ] Subsequent generations in same session reuse the cache
- [ ] Time-to-first-token for turn 2+ is measurably faster than turn 1 (target: 50%+ reduction)
- [ ] KV cache is cleared when `AgentLoop.endSession()` is called
- [ ] Memory usage logged via `GPU.snapshot()` before/after to verify cache behavior
- [ ] No regression in first-turn latency

---

## 7. Verification Plan

### Automated Tests
- Unit test: Verify cache object is reused across multiple generate calls
- Unit test: Verify cache is nil/cleared after session end

### Manual Tests
- [ ] Start conversation, note time-to-first-token for first response
- [ ] Send follow-up message, verify faster response time
- [ ] End session, start new conversation, verify cache was cleared (first message is slower again)
- [ ] Monitor memory with `footprint` during multi-turn conversation

### Benchmarks
- Measure TTFT (time-to-first-token) for turns 1, 2, 3 in a conversation
- Target: Turn 2+ should be 50%+ faster than turn 1

---

## 8. Research References

- Apple WWDC 2025: "Explore large language models on Apple silicon with MLX"
- MLX Swift `newCache` / `TokenIterator` API
- Community: KV cache can consume hundreds of MB for long conversations
