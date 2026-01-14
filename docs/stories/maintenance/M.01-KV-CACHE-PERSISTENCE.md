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

### Current Implementation Analysis

**LLMService.swift** currently uses the deprecated MLX API:
```swift
let _ = try MLXLMCommon.generate(
    promptTokens: inputTokens,
    parameters: parameters,
    model: context.model,
    tokenizer: context.tokenizer,
    didGenerate: { tokens in ... }
)
```

This API internally creates a new cache for each generation, discarding it afterward.

### Target Implementation Pattern

MLX Swift provides `TokenIterator` with an optional cache parameter:
```swift
public init(
    input: LMInput, 
    model: any LanguageModel, 
    cache: [KVCache]? = nil,  // <-- Pass existing cache here
    parameters: GenerateParameters
) throws {
    self.cache = cache ?? model.newCache(parameters: parameters)
    // ...
}
```

**Key Insight**: If you pass `nil` for cache, a new one is created. If you pass an existing cache, it will be reused and updated with new tokens.

The `ChatSession` class from MLX demonstrates the pattern:
```swift
if cache.isEmpty {
    cache = context.model.newCache(parameters: generateParameters)
}
// Then reuse `cache` in subsequent generations
```

### Memory Impact
- KV cache grows with conversation length (~hundreds of MB for long chats)
- Still more efficient than re-feeding full history each turn
- Must clear cache when conversation ends to reclaim memory

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- None required

### 5.2 Files to Modify

#### `Ora/LLM/Types.swift`
Add `clearCache()` method to protocol:
```swift
public protocol LLMServicing: Sendable {
    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error>
    func warmup() async throws
    func prepare() async throws
    func unload() async
    func clearCache() async  // NEW: Clear KV cache for new session
}
```

#### `Ora/LLM/LLMService.swift`

**1. Add cache storage property:**
```swift
actor LLMService: LLMServicing {
    // ... existing properties ...
    
    /// Persistent KV cache for multi-turn conversations
    /// Created on first generation, reused across turns, cleared on session end
    private var kvCache: [KVCache]?
}
```

**2. Add `clearCache()` method:**
```swift
/// Clear the KV cache to start fresh
/// Call this when ending a session or starting a new conversation
func clearCache() async {
    if kvCache != nil {
        logger.info("Clearing KV cache")
        kvCache = nil
        // Clear GPU cache to actually release the memory
        GPU.clearCache()
    }
}
```

**3. Modify `runGeneration()` to use persistent cache:**

Replace the current implementation with the modern API that accepts a cache:
```swift
private func runGeneration(
    messages: [LLMMessage],
    maxTokens: Int,
    continuation: AsyncThrowingStream<LLMDelta, Error>.Continuation
) async throws {
    guard isReady, let container = modelContainer else {
        throw LLMServiceError.notReady
    }
    
    let chatMessages: [[String: any Sendable]] = messages.map { msg in
        ["role": msg.role.rawValue, "content": msg.content]
    }
    let fallbackPrompt = formatMessagesLegacy(messages)
    
    self.logger.debug("Generating with \(messages.count) messages")
    
    let parameters = GenerateParameters(
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP
    )
    
    try await MLXMetalGate.shared.withExclusiveAccess {
        try await container.perform { context in
            // Tokenize input
            let inputTokens: [Int]
            do {
                inputTokens = try context.tokenizer.applyChatTemplate(messages: chatMessages)
            } catch {
                inputTokens = context.tokenizer.encode(text: fallbackPrompt)
            }
            
            let input = LMInput(tokens: MLXArray(inputTokens))
            
            // Initialize cache on first generation, reuse on subsequent
            if self.kvCache == nil {
                self.logger.info("Creating new KV cache for session")
                self.kvCache = context.model.newCache(parameters: parameters)
            } else {
                self.logger.debug("Reusing existing KV cache (offset: \(self.kvCache?.first?.offset ?? 0))")
            }
            
            // Create iterator with persistent cache
            let iterator = try TokenIterator(
                input: input,
                model: context.model,
                cache: self.kvCache,
                parameters: parameters
            )
            
            var count = 0
            
            // Iterate using the modern async pattern
            for await generation in MLXLMCommon.generate(
                input: input,
                context: context,
                iterator: iterator
            ) {
                if Task.isCancelled { break }
                
                if let chunk = generation.chunk {
                    continuation.yield(.token(chunk))
                    count += 1
                    
                    // Stop on end-of-turn tokens
                    if chunk.contains("<|im_end|>") || 
                       chunk.contains("<|endoftext|>") ||
                       chunk.contains("</tool_call>") {
                        break
                    }
                }
            }
            
            Stream.gpu.synchronize()
        }
    }
    
    // Don't clear cache here - it persists for the session
    // Only clear GPU buffer cache, not the KV cache
    GPU.clearCache()
    
    continuation.yield(.completed(totalTokens: 0))
    continuation.finish()
    
    self.logger.debug("Generation complete")
}
```

**4. Update `unload()` to clear cache:**
```swift
func unload() async {
    guard isReady else { return }
    
    logger.info("Unloading LLM model...")
    
    // Clear KV cache first
    kvCache = nil
    
    modelContainer = nil
    isReady = false
    isWarmedUp = false
    
    // Clear GPU cache
    GPU.clearCache()
    
    logger.info("LLM model unloaded")
    
    NotificationCenter.default.post(name: Notification.Name("LLMModelUnloaded"), object: nil)
}
```

#### `Ora/Orchestration/AgentLoop.swift`

**Modify `endSession()` to clear cache:**
```swift
func endSession() async {
    self.sessionActive = false
    self.pendingProposal = nil
    self.currentSessionID = nil
    
    // Clear conversation to free memory
    await conversationManager.clear()
    
    // Clear KV cache to free GPU memory
    await LLMService.shared.clearCache()
    
    logger.debug("Agent session ended")
}
```

#### `Ora/LLM/ConversationManager.swift`

**Modify `startConversation()` to clear cache when starting fresh:**
```swift
func startConversation(systemPrompt: String) {
    self.systemPrompt = systemPrompt
    self.messages = []
    
    // Clear KV cache when starting a new conversation
    // (Do this asynchronously to avoid blocking)
    Task {
        await LLMService.shared.clearCache()
    }
    
    logger.debug("Started new conversation with system prompt (\(systemPrompt.count) chars)")
}
```

### 5.2 Required Imports

In `LLMService.swift`, ensure these imports are present:
```swift
import MLXLMCommon  // For LMInput, TokenIterator, GenerateParameters, KVCache
```

### 5.3 Tests to Add

#### `OraTests/LLM/LLMServiceTests.swift`

```swift
func testKVCacheReuse() async throws {
    let service = LLMService.shared
    
    // Skip if no model available
    let modelManager = ModelManager.shared
    await modelManager.refreshStatuses()
    let state = await modelManager.state
    
    guard state.statuses[.qwen3_4B]?.isReady == true else {
        throw XCTSkip("Qwen 3 4B not downloaded")
    }
    
    try await service.prepare()
    
    // First generation (cache should be created)
    let messages1 = [LLMMessage(role: .user, content: "Hello")]
    var text1 = ""
    let stream1 = await service.generate(messages: messages1, maxTokens: 10)
    for try await delta in stream1 {
        if case .token(let t) = delta { text1 += t }
    }
    XCTAssertFalse(text1.isEmpty)
    
    // Second generation (cache should be reused)
    // Time-to-first-token should be faster
    let messages2 = [
        LLMMessage(role: .user, content: "Hello"),
        LLMMessage(role: .assistant, content: text1),
        LLMMessage(role: .user, content: "How are you?")
    ]
    var text2 = ""
    let stream2 = await service.generate(messages: messages2, maxTokens: 10)
    for try await delta in stream2 {
        if case .token(let t) = delta { text2 += t }
    }
    XCTAssertFalse(text2.isEmpty)
    
    // Clear cache
    await service.clearCache()
    
    await service.unload()
}

func testCacheClearedOnUnload() async throws {
    let service = LLMService.shared
    
    guard let _ = await ModelManager.shared.pathForModel(.qwen3_4B) else {
        throw XCTSkip("Qwen 3 4B not downloaded")
    }
    
    try await service.prepare()
    
    // Generate to create cache
    let stream = await service.generate(
        messages: [LLMMessage(role: .user, content: "Hi")],
        maxTokens: 5
    )
    for try await _ in stream {}
    
    // Unload should clear cache
    await service.unload()
    
    // Re-prepare and verify cache is fresh
    try await service.prepare()
    // No crash = success (cache was properly cleared)
    await service.unload()
}
```

---

## 6. Acceptance Criteria

- [ ] KV cache is created on first generation of a session
- [ ] Subsequent generations in same session reuse the cache
- [ ] Time-to-first-token for turn 2+ is measurably faster than turn 1 (target: 50%+ reduction)
- [ ] KV cache is cleared when `AgentLoop.endSession()` is called
- [ ] KV cache is cleared when `ConversationManager.startConversation()` is called
- [ ] KV cache is cleared when `LLMService.unload()` is called
- [ ] Memory usage does not grow unboundedly across sessions
- [ ] No regression in first-turn latency
- [ ] Unit tests pass for cache lifecycle

---

## 7. Verification Plan

### Automated Tests
- Unit test: Verify cache object is reused across multiple generate calls
- Unit test: Verify cache is nil/cleared after session end
- Unit test: Verify no crash when clearing cache that doesn't exist

### Manual Tests
- [ ] Start conversation, note time-to-first-token for first response
- [ ] Send follow-up message, verify faster response time (check logs for "Reusing existing KV cache")
- [ ] End session, start new conversation, verify cache was cleared (check logs for "Creating new KV cache")
- [ ] Monitor memory with Activity Monitor during multi-turn conversation
- [ ] Verify memory is released after ending session

### Benchmarks
- Measure TTFT (time-to-first-token) for turns 1, 2, 3 in a conversation
- Target: Turn 2+ should be 50%+ faster than turn 1

---

## 8. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Cache grows too large for long conversations | Future: Implement RotatingKVCache with max size |
| Memory not released after clear | Verify GPU.clearCache() is called after setting kvCache = nil |
| Race condition on cache access | LLMService is an actor - inherently thread-safe |
| Cache invalidation on model switch | unload() clears cache; prepare() doesn't restore it |

---

## 9. Research References

- Apple WWDC 2025: "Explore large language models on Apple silicon with MLX"
- MLX Swift `TokenIterator` and `KVCache` APIs
- MLX Swift `ChatSession` implementation pattern
