//
//  ConversationManagerTests.swift
//  OraTests
//
//  Unit tests for ConversationManager
//

import XCTest
@testable import Ora

final class ConversationManagerTests: XCTestCase {
    
    // MARK: - AC-1: System Prompt Tests

    func test_defaultMaxContextTokens_is32000() {
        XCTAssertEqual(ConversationManager.defaultMaxContextTokens, 32_000)
    }
    
    func test_systemPromptIncludedAsFirstMessage() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        await manager.startConversation(systemPrompt: "You are a helpful assistant.")
        await manager.addUserMessage("Hello")
        
        let messages = await manager.getMessagesForLLM()
        
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "You are a helpful assistant.")
        XCTAssertEqual(messages[1].role, .user)
    }

    func test_estimateTotalTokens_freshSessionUnderDefaultBudget() async {
        let manager = ConversationManager.makeTestInstance()
        let prompt = await self.makeRealisticSystemPrompt()

        await manager.startConversation(systemPrompt: prompt)

        let tokens = await manager.estimateTotalTokens()
        XCTAssertGreaterThan(tokens, 0)
        XCTAssertLessThan(tokens, ConversationManager.defaultMaxContextTokens)
    }
    
    func test_emptySystemPromptNotIncluded() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        await manager.startConversation(systemPrompt: "")
        await manager.addUserMessage("Hello")
        
        let messages = await manager.getMessagesForLLM()
        
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
    }
    
    // MARK: - AC-2: Message Types and Ordering
    
    func test_messagesCorrectlyTypedAndOrdered() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        await manager.startConversation(systemPrompt: "System prompt")
        await manager.addUserMessage("User message")
        await manager.addAssistantMessage("Assistant message")
        await manager.addToolResult("Tool result")
        await manager.addAssistantMessage("Final response")
        
        let messages = await manager.getMessagesForLLM()
        
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[1].role, .user)
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[3].role, .tool)
        XCTAssertEqual(messages[4].role, .assistant)
        
        // Verify content is preserved
        XCTAssertEqual(messages[1].content, "User message")
        XCTAssertEqual(messages[2].content, "Assistant message")
        XCTAssertEqual(messages[3].content, "Tool result")
        XCTAssertEqual(messages[4].content, "Final response")
    }
    
    // MARK: - AC-3: Context Trimming When Exceeding Limit
    
    func test_contextTrimmedWhenExceedingLimit() async {
        // Use a very small token limit to force trimming
        // At 0.3 tokens/char, 100 tokens = ~333 characters
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 100)
        
        await manager.startConversation(systemPrompt: "Short system prompt")
        
        // Add several long messages that will exceed the limit
        let longMessage = String(repeating: "a", count: 200) // ~60 tokens each
        await manager.addUserMessage(longMessage)
        await manager.addAssistantMessage(longMessage)
        await manager.addUserMessage(longMessage)
        await manager.addAssistantMessage(longMessage)
        
        // Should have trimmed to stay under limit (keeps minimum of 1 message)
        let messageCount = await manager.messageCount()
        XCTAssertEqual(messageCount, 1, "Should keep minimum of 1 message")
    }
    
    // MARK: - AC-4: FIFO Trimming Preserves System Prompt
    
    func test_systemPromptPreservedDuringTrimming() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 100)
        
        let systemPrompt = "Important system instructions"
        await manager.startConversation(systemPrompt: systemPrompt)
        
        // Add messages that will trigger trimming
        let longMessage = String(repeating: "x", count: 200)
        await manager.addUserMessage(longMessage)
        await manager.addAssistantMessage(longMessage)
        await manager.addUserMessage("Latest question")
        
        let messages = await manager.getMessagesForLLM()
        
        // System prompt should always be first
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, systemPrompt)
    }
    
    func test_oldestMessagesRemovedFirst() async {
        // Token limit very small to force trimming
        // At 0.3 tokens/char, 50 tokens = ~166 chars
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 50)
        
        // System: "sys" = ~1 token
        await manager.startConversation(systemPrompt: "sys")
        
        // Add messages that will accumulate tokens
        // first: 100 chars = ~30 tokens, total = ~31
        await manager.addUserMessage(String(repeating: "a", count: 100))
        
        // second: 100 chars = ~30 tokens, total = ~61 (over limit!)
        // This should trigger trimming, keeping min 1 message
        await manager.addAssistantMessage(String(repeating: "b", count: 100))
        
        // third: 100 chars = ~30 tokens
        // After trim, we should have only the newest message
        await manager.addUserMessage(String(repeating: "c", count: 100))
        
        // fourth: 100 chars = ~30 tokens  
        // Should continue trimming older messages
        await manager.addAssistantMessage(String(repeating: "d", count: 100))
        
        let messages = await manager.getMessagesForLLM()
        
        // Should have system + exactly 1 message (the minimum)
        XCTAssertEqual(messages.count, 2, "Should have system + 1 message")
        
        // Verify system is first
        XCTAssertEqual(messages[0].role, .system)
        
        // Verify older messages were removed, keeping newest one
        let contents = messages.map { $0.content }
        XCTAssertFalse(contents.contains(String(repeating: "a", count: 100)), "First message should be trimmed")
        XCTAssertFalse(contents.contains(String(repeating: "b", count: 100)), "Second message should be trimmed")
        XCTAssertFalse(contents.contains(String(repeating: "c", count: 100)), "Third message should be trimmed")
        XCTAssertTrue(contents.contains(String(repeating: "d", count: 100)), "Fourth (latest) message should be kept")
    }
    
    // MARK: - AC-5: Clear Resets State
    
    func test_clearResetsConversationCompletely() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        await manager.startConversation(systemPrompt: "System prompt")
        await manager.addUserMessage("Hello")
        await manager.addAssistantMessage("Hi there")
        
        // Verify we have messages
        var count = await manager.messageCount()
        XCTAssertEqual(count, 2)
        
        // Clear
        await manager.clear()
        
        // Verify everything is reset
        count = await manager.messageCount()
        XCTAssertEqual(count, 0)
        
        let systemPrompt = await manager.getSystemPrompt()
        XCTAssertEqual(systemPrompt, "")
        
        let messages = await manager.getMessagesForLLM()
        XCTAssertEqual(messages.count, 0)
    }
    
    // MARK: - AC-6: Token Estimation
    
    func test_tokenEstimationUsesCorrectHeuristic() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        // 1000 chars * 0.3 = 300 tokens
        let message = String(repeating: "a", count: 1000)
        await manager.startConversation(systemPrompt: message)
        
        let tokens = await manager.estimateTotalTokens()
        XCTAssertEqual(tokens, 300, "1000 chars should estimate to 300 tokens at 0.3 tokens/char")
    }
    
    func test_tokenEstimationIncludesAllContent() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        // System: 100 chars = 30 tokens
        // User: 100 chars = 30 tokens
        // Assistant: 100 chars = 30 tokens
        // Total: 90 tokens
        let content = String(repeating: "b", count: 100)
        await manager.startConversation(systemPrompt: content)
        await manager.addUserMessage(content)
        await manager.addAssistantMessage(content)
        
        let tokens = await manager.estimateTotalTokens()
        XCTAssertEqual(tokens, 90)
    }
    
    // MARK: - Additional Tests
    
    func test_getConversationReturnsMessagesWithoutSystemPrompt() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        await manager.startConversation(systemPrompt: "System")
        await manager.addUserMessage("User")
        await manager.addAssistantMessage("Assistant")
        
        let conversation = await manager.getConversation()
        
        XCTAssertEqual(conversation.count, 2)
        XCTAssertEqual(conversation[0].role, .user)
        XCTAssertEqual(conversation[1].role, .assistant)
    }
    
    func test_startConversationClearsPreviousMessages() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        await manager.startConversation(systemPrompt: "First")
        await manager.addUserMessage("Hello")
        
        // Start new conversation
        await manager.startConversation(systemPrompt: "Second")
        
        let messages = await manager.getMessagesForLLM()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "Second")
        
        let count = await manager.messageCount()
        XCTAssertEqual(count, 0)
    }
    
    func test_multiTurnConversation() async {
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        await manager.startConversation(systemPrompt: "You are a helpful assistant.")
        
        // Simulate multi-turn conversation
        await manager.addUserMessage("What's the weather like?")
        await manager.addAssistantMessage("I can check that for you.")
        await manager.addToolResult("{\"temperature\": 72, \"condition\": \"sunny\"}")
        await manager.addAssistantMessage("It's 72°F and sunny today.")
        await manager.addUserMessage("Thanks! What about tomorrow?")
        await manager.addAssistantMessage("Let me check tomorrow's forecast.")
        
        let messages = await manager.getMessagesForLLM()
        
        // System + 6 conversation messages
        XCTAssertEqual(messages.count, 7)
        
        // Verify order is preserved
        XCTAssertEqual(messages[1].content, "What's the weather like?")
        XCTAssertEqual(messages[5].content, "Thanks! What about tomorrow?")
    }

    func test_defaultBudget_doesNotTrimTwentyTurnConversation() async {
        let manager = ConversationManager.makeTestInstance()
        let prompt = await self.makeRealisticSystemPrompt()
        let userMessage = String(repeating: "u", count: 200)
        let assistantMessage = String(repeating: "a", count: 200)

        await manager.startConversation(systemPrompt: prompt)

        for _ in 1...20 {
            await manager.addUserMessage(userMessage)
            await manager.addAssistantMessage(assistantMessage)
        }

        let messageCount = await manager.messageCount()
        XCTAssertEqual(messageCount, 40, "Default 32K budget should retain all 20 turns")
    }

    func test_memoryContext_whenSet_includesAdditionalSystemMessage() async {
        // Given
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await manager.startConversation(systemPrompt: "Base system prompt")
        await manager.addUserMessage("What did we decide?")
        await manager.setMemoryContext("Relevant memory chunk")

        // When
        let messages = await manager.getMessagesForLLM()

        // Then
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "Base system prompt")
        XCTAssertEqual(messages[1].role, .system)
        XCTAssertEqual(messages[1].content, "Relevant memory chunk")
        XCTAssertEqual(messages[2].role, .user)
    }

    func test_memoryContext_includedInTokenEstimate() async {
        // Given — memory context should count toward the token budget
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        let systemPrompt = String(repeating: "s", count: 100)  // 30 tokens
        let memoryCtx = String(repeating: "m", count: 200)      // 60 tokens
        await manager.startConversation(systemPrompt: systemPrompt)
        await manager.setMemoryContext(memoryCtx)

        // When
        let tokens = await manager.estimateTotalTokens()

        // Then — 100 * 0.3 + 200 * 0.3 = 30 + 60 = 90
        XCTAssertEqual(tokens, 90)
    }

    func test_memoryContext_countedInTrimmingBudget() async {
        // Given — large memory context should cause conversation messages to be trimmed
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 300)
        // System: 100 chars = 30 tokens
        await manager.startConversation(systemPrompt: String(repeating: "s", count: 100))
        // Memory: 500 chars = 150 tokens (30 + 150 = 180 tokens used by fixed context)
        await manager.setMemoryContext(String(repeating: "m", count: 500))

        // Add several messages (each 200 chars = 60 tokens)
        // Budget remaining: 300 - 180 = 120 tokens => room for 2 messages at 60 tokens each
        await manager.addUserMessage(String(repeating: "a", count: 200))       // +60 = 240
        await manager.addAssistantMessage(String(repeating: "b", count: 200))  // +60 = 300
        await manager.addUserMessage(String(repeating: "c", count: 200))       // +60 = 360 → triggers trim

        // When
        let conversation = await manager.getConversation()

        // Then — at least one old message should have been trimmed to fit budget
        XCTAssertLessThan(conversation.count, 3, "Memory context should reduce room for conversation messages")
    }

    func test_memoryContext_whenCleared_excludesAdditionalSystemMessage() async {
        // Given
        let manager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        await manager.startConversation(systemPrompt: "Base system prompt")
        await manager.addUserMessage("Follow up")
        await manager.setMemoryContext("Temporary memory context")
        await manager.clearMemoryContext()

        // When
        let messages = await manager.getMessagesForLLM()

        // Then
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[1].role, .user)
    }

    // MARK: - Helpers

    private func makeRealisticSystemPrompt() async -> String {
        let registry = ToolRegistry.makeTestInstance()
        await registry.registerDefaultTools()
        let schemas = await registry.schemas()

        let definitions = schemas.map { schema in
            ToolDefinition(
                name: schema.name,
                description: schema.description,
                parameterSchemas: schema.parameters.mapValues { parameter in
                    ToolParameterDefinition(type: parameter.type, format: parameter.format)
                },
                requiredParameters: schema.requiredParameters,
                requiresConfirmation: schema.requiresConfirmation
            )
        }

        return SystemPromptBuilder.build(tools: definitions)
    }
}
