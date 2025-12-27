# L.03 - Conversation Manager

**Epic:** LLM Integration
**Status:** Not Started
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

- [ ] **AC-1:** System prompt included in LLM messages
- [ ] **AC-2:** User/assistant/tool messages tracked
- [ ] **AC-3:** Context trimmed when exceeding budget
- [ ] **AC-4:** Oldest messages removed first
- [ ] **AC-5:** Clear resets conversation state

---

## 4. Implementation Checklist

- [ ] Create `ConversationManager.swift`
- [ ] Integrate with persistence (Session model)
- [ ] Test context trimming
- [ ] Test multi-turn conversations
