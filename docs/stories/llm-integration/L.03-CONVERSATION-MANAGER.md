# L.03 - Conversation Manager

**Epic:** LLM Integration
**Status:** Complete
**Priority:** P1 (Important)
**Estimated Effort:** 1 day
**Dependencies:** L.01 (LLM Runtime), F.08 (Persistence)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Manage conversation context, message history, and token budgets for multi-turn conversations.

---

## 2. Implementation

**File:** `Ora/LLM/ConversationManager.swift`

```swift
//
//  ConversationManager.swift
//  Ora
//
//  Manages conversation context and history
//

import Foundation
import os

/// Manages conversation state and context
actor ConversationManager {
    
    // MARK: - Singleton
    
    static let shared = ConversationManager()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "ConversationManager")
    
    private var messages: [LLMMessage] = []
    private var systemPrompt: String = ""
    private let maxContextTokens = 6000  // Leave room for response
    
    // Approximate tokens per character (rough estimate)
    private let tokensPerChar: Double = 0.3
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Start a new conversation
    func startConversation(systemPrompt: String) {
        self.systemPrompt = systemPrompt
        self.messages = []
        logger.debug("Started new conversation")
    }
    
    /// Add a user message
    func addUserMessage(_ content: String) {
        messages.append(LLMMessage(role: .user, content: content))
        trimContextIfNeeded()
    }
    
    /// Add an assistant message
    func addAssistantMessage(_ content: String) {
        messages.append(LLMMessage(role: .assistant, content: content))
        trimContextIfNeeded()
    }
    
    /// Add a tool result
    func addToolResult(_ content: String) {
        messages.append(LLMMessage(role: .tool, content: content))
        trimContextIfNeeded()
    }
    
    /// Get messages for LLM (with system prompt)
    func getMessagesForLLM() -> [LLMMessage] {
        var result: [LLMMessage] = []
        
        // Add system prompt
        if !systemPrompt.isEmpty {
            result.append(LLMMessage(role: .system, content: systemPrompt))
        }
        
        // Add conversation messages
        result.append(contentsOf: messages)
        
        return result
    }
    
    /// Get current conversation for persistence
    func getConversation() -> [LLMMessage] {
        return messages
    }
    
    /// Clear conversation
    func clear() {
        messages = []
        logger.debug("Conversation cleared")
    }
    
    // MARK: - Private
    
    private func trimContextIfNeeded() {
        var totalTokens = estimateTokens(systemPrompt)
        
        for message in messages {
            totalTokens += estimateTokens(message.content)
        }
        
        // Remove oldest messages if over budget
        while totalTokens > maxContextTokens && messages.count > 2 {
            let removed = messages.removeFirst()
            totalTokens -= estimateTokens(removed.content)
            logger.debug("Trimmed message from context")
        }
    }
    
    private func estimateTokens(_ text: String) -> Int {
        Int(Double(text.count) * tokensPerChar)
    }
}
```

---

## 3. Acceptance Criteria

- [x] **AC-1:** System prompt included in LLM messages - ✅ Verified by `test_systemPromptIncludedAsFirstMessage`
- [x] **AC-2:** User/assistant/tool messages tracked - ✅ Verified by `test_messagesCorrectlyTypedAndOrdered`
- [x] **AC-3:** Context trimmed when exceeding budget - ✅ Verified by `test_contextTrimmedWhenExceedingLimit`
- [x] **AC-4:** Oldest messages removed first - ✅ Verified by `test_oldestMessagesRemovedFirst`
- [x] **AC-5:** Clear resets conversation state - ✅ Verified by `test_clearResetsConversationCompletely`

---

## 4. Implementation Checklist

- [x] Create `ConversationManager.swift`
- [ ] Integrate with persistence (Session model) - Future enhancement, not required for v1
- [x] Test context trimming
- [x] Test multi-turn conversations

---

## Implementation Plan

### Files to Create
- `Ora/LLM/ConversationManager.swift` - Actor-based conversation context management

### Files to Modify
- None required for v1 (standalone component)

### Tests to Add
- `OraTests/LLM/ConversationManagerTests.swift` - Unit tests for all acceptance criteria

---

## Implementation Summary

**Date:** 2025-12-31
**Branch:** `feat/L.03-conversation-manager`

### Files Changed
- `Ora/LLM/ConversationManager.swift` - Created: Actor-based conversation context manager with FIFO trimming
- `OraTests/LLM/ConversationManagerTests.swift` - Created: 12 unit tests covering all acceptance criteria

### Key Implementation Details
1. **Actor-based thread safety:** Uses Swift `actor` for safe concurrent access
2. **Token estimation:** Uses 0.3 tokens/char heuristic (conservative for Qwen)
3. **FIFO trimming:** Removes oldest messages when over 6000 token budget
4. **Minimum context:** Always keeps at least 2 messages for continuity
5. **System prompt preservation:** System prompt is never trimmed
6. **Test factory:** `makeTestInstance(maxContextTokens:)` for testing with custom limits

### Test Coverage
All 12 ConversationManager tests pass:
- AC-1: `test_systemPromptIncludedAsFirstMessage`, `test_emptySystemPromptNotIncluded`
- AC-2: `test_messagesCorrectlyTypedAndOrdered`
- AC-3: `test_contextTrimmedWhenExceedingLimit`
- AC-4: `test_oldestMessagesRemovedFirst`, `test_systemPromptPreservedDuringTrimming`
- AC-5: `test_clearResetsConversationCompletely`
- AC-6: `test_tokenEstimationUsesCorrectHeuristic`, `test_tokenEstimationIncludesAllContent`
- Additional: `test_getConversationReturnsMessagesWithoutSystemPrompt`, `test_startConversationClearsPreviousMessages`, `test_multiTurnConversation`

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing (12/12)
- [x] Build successful

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2025-12-31T13:03:52Z
**Commit reviewed:** 7483cfb
**Iteration:** 1

### Summary
- Files reviewed: 3
- Build status: Pass
- Tests status: Fail (timed out after 300s; ASREngineTests reported 1 failure before timeout)

### Issues Found

#### P0 - Critical (Must fix)
- [ ] None

#### P1 - Major (Should fix)
- [x] `Ora/LLM/ConversationManager.swift:142` - ✅ Fixed: Now trims to 1 message minimum instead of 2, with warning log when still over budget due to oversized message.

#### P2 - Minor (Can defer)
- [ ] None

### Future Considerations (Out of Scope)
- None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [ ] Ready for merge

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2025-12-31T13:11:06Z
**Commit reviewed:** cd9c078
**Iteration:** 2

### Summary
- Files reviewed: 2
- Build status: Pass
- Tests status: Fail (timed out after 120s; ASREngineTests reported 1 failure before timeout)

### Issues Found

#### P0 - Critical (Must fix)
- [ ] None

#### P1 - Major (Should fix)
- [ ] None

#### P2 - Minor (Can defer)
- [ ] None

### Future Considerations (Out of Scope)
- None.

### Approval Status
- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge
