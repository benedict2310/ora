//
//  AgentLoopTests.swift
//  OraTests
//
//  Tests for AgentLoop
//

import XCTest
@testable import Ora

// MARK: - Mock LLM Service

/// Mock LLM service for testing agent loop
actor AgentLoopMockLLMService: LLMServicing {
    var responses: [String] = []
    private var responseIndex = 0
    
    func setResponses(_ responses: [String]) {
        self.responses = responses
        self.responseIndex = 0
    }
    
    func warmup() async throws {
        // No-op for testing
    }
    
    func prepare() async throws {
        // No-op for testing
    }
    
    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        let response = responseIndex < responses.count ? responses[responseIndex] : "{\"type\": \"response\", \"text\": \"Default\"}"
        responseIndex += 1
        
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.finish()
        }
    }
    
    func unload() async {
        // No-op
    }
    
    func clearCache() async {
        // No-op for testing
    }
}

actor AgentLoopMockFailingLLMService: LLMServicing {
    func warmup() async throws {}
    func prepare() async throws {}
    func unload() async {}
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError.noCredential(.openai))
        }
    }
}

actor AgentLoopMockModelUnavailableLLMService: LLMServicing {
    func warmup() async throws {}
    func prepare() async throws {}
    func unload() async {}
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: CloudProviderError.requestFailed(
                    statusCode: 404,
                    body: "The model `gpt-5.2` does not exist or you do not have access to it."
                )
            )
        }
    }
}

actor AgentLoopMockRequestShapeRejectedLLMService: LLMServicing {
    func warmup() async throws {}
    func prepare() async throws {}
    func unload() async {}
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: CloudProviderError.requestFailed(
                    statusCode: 400,
                    body: "invalid_request_error: Invalid role value in input payload."
                )
            )
        }
    }
}

// MARK: - Mock Tool

/// Mock tool for testing agent loop
struct AgentLoopMockReadTool: Tool {
    let name: String
    let kind: ToolKind = .read
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Test read tool",
            parameters: [:],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }
    
    let result: String
    
    func validate(args: [String: JSONValue]) throws {
        // Accept all args
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        return .success(.string(result), summary: result)
    }
}

struct AgentLoopMockMutateTool: Tool {
    let name: String
    let kind: ToolKind = .mutate
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Test mutate tool",
            parameters: [:],
            requiredParameters: [],
            requiresConfirmation: true
        )
    }
    
    let result: String
    
    func validate(args: [String: JSONValue]) throws {
        // Accept all args
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        return .success(.string(result), summary: result)
    }
}

// MARK: - Tests

final class AgentLoopTests: XCTestCase {
    
    var mockLLM: AgentLoopMockLLMService!
    var structuredGenerator: StructuredGenerator!
    var toolRegistry: ToolRegistry!
    var conversationManager: ConversationManager!
    var agentLoop: AgentLoop!
    
    override func setUp() async throws {
        mockLLM = AgentLoopMockLLMService()
        structuredGenerator = StructuredGenerator(llm: mockLLM)
        toolRegistry = ToolRegistry.makeTestInstance()
        conversationManager = ConversationManager.makeTestInstance(maxContextTokens: 6000)
        
        agentLoop = AgentLoop(
            maxStepsPerTurn: 6,
            maxToolCallsPerTurn: 3,
            maxTokensPerTurn: 800,
            structuredGenerator: structuredGenerator,
            toolHost: .shared,
            toolRegistry: toolRegistry,
            conversationManager: conversationManager
        )
    }
    
    // MARK: - Response Tests
    
    func test_process_simpleResponse_returnsResponseResult() async throws {
        // Given: LLM returns a simple response
        await mockLLM.setResponses([
            """
            {"type": "response", "text": "Hello, I'm Ora!"}
            """
        ])
        
        // When: Process user input
        let result = try await agentLoop.process(userText: "Hello")
        
        // Then: Should return response
        if case .response(let text) = result {
            XCTAssertEqual(text, "Hello, I'm Ora!")
        } else {
            XCTFail("Expected response result, got \(result)")
        }
    }
    
    func test_process_addsUserMessageToConversation() async throws {
        // Given: LLM returns a simple response
        await mockLLM.setResponses([
            """
            {"type": "response", "text": "Got it"}
            """
        ])
        
        // When: Process user input
        _ = try await agentLoop.process(userText: "Test message")
        
        // Then: Conversation should have user message
        let messages = await conversationManager.getConversation()
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content == "Test message" })
    }
    
    func test_process_addsAssistantResponseToConversation() async throws {
        // Given: LLM returns a simple response
        await mockLLM.setResponses([
            """
            {"type": "response", "text": "Hello there!"}
            """
        ])
        
        // When: Process user input
        _ = try await agentLoop.process(userText: "Hi")
        
        // Then: Conversation should have assistant message
        let messages = await conversationManager.getConversation()
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "Hello there!" })
    }
    
    // MARK: - Proposal Tests
    
    func test_process_proposal_returnsProposalResult() async throws {
        // Given: LLM returns a proposal
        await mockLLM.setResponses([
            """
            {"type": "proposal", "summary": "Create event", "tool": "calendar.create", "args": {"title": "Meeting"}}
            """
        ])
        
        // When: Process user input
        let result = try await agentLoop.process(userText: "Schedule a meeting")
        
        // Then: Should return proposal
        if case .proposal(let summary, let tool, let args) = result {
            XCTAssertEqual(summary, "Create event")
            XCTAssertEqual(tool, "calendar.create")
            XCTAssertEqual(args["title"]?.stringValue, "Meeting")
        } else {
            XCTFail("Expected proposal result, got \(result)")
        }
    }
    
    // MARK: - Tool Call Tests
    
    func test_process_toolCall_executesAndContinues() async throws {
        // Given: LLM calls a tool then responds
        await toolRegistry.register(AgentLoopMockReadTool(name: "test.query", result: "Query result"))
        
        await mockLLM.setResponses([
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """,
            """
            {"type": "response", "text": "Based on the query: Query result"}
            """
        ])
        
        // When: Process user input
        let result = try await agentLoop.process(userText: "Query something")
        
        // Then: Should return final response after tool execution
        if case .response(let text) = result {
            XCTAssertTrue(text.contains("Query result"))
        } else {
            XCTFail("Expected response result, got \(result)")
        }
    }
    
    func test_process_toolCallLimit_returnsError() async throws {
        // Given: LLM keeps calling tools beyond limit (3)
        await toolRegistry.register(AgentLoopMockReadTool(name: "test.query", result: "Result"))
        
        await mockLLM.setResponses([
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """,
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """,
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """,
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """
        ])
        
        // When: Process user input
        let result = try await agentLoop.process(userText: "Keep querying")
        
        // Then: Should return error after reaching limit
        if case .error(let message) = result {
            XCTAssertTrue(message.contains("limit"))
        } else {
            XCTFail("Expected error result, got \(result)")
        }
    }
    
    // MARK: - Budget Tests
    
    func test_process_stepBudgetExhausted_returnsError() async throws {
        // Given: Agent loop with max 2 steps
        let limitedLoop = AgentLoop(
            maxStepsPerTurn: 2,
            maxToolCallsPerTurn: 10,
            maxTokensPerTurn: 800,
            structuredGenerator: structuredGenerator,
            toolHost: .shared,
            toolRegistry: toolRegistry,
            conversationManager: conversationManager
        )
        
        await toolRegistry.register(AgentLoopMockReadTool(name: "test.query", result: "Result"))
        
        await mockLLM.setResponses([
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """,
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """,
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """
        ])
        
        // When: Process user input
        let result = try await limitedLoop.process(userText: "Query")
        
        // Then: Should return error after exhausting step budget
        if case .error(let message) = result {
            XCTAssertTrue(message.contains("complete"))
        } else {
            XCTFail("Expected error result, got \(result)")
        }
    }
    
    // MARK: - Error Tests
    
    func test_process_llmError_returnsErrorResult() async throws {
        // Given: LLM returns an error type
        await mockLLM.setResponses([
            """
            {"type": "error", "message": "Cannot process that request"}
            """
        ])
        
        // When: Process user input
        let result = try await agentLoop.process(userText: "Do something impossible")
        
        // Then: Should return error
        if case .error(let message) = result {
            XCTAssertEqual(message, "Cannot process that request")
        } else {
            XCTFail("Expected error result, got \(result)")
        }
    }

    func test_process_structuredOutputFailure_returnsActionableFormattingMessage() async throws {
        await mockLLM.setResponses([
            "not-json",
            "still-not-json",
            "also-not-json",
        ])

        let result = try await agentLoop.process(userText: "Trigger invalid structure")

        if case .error(let message) = result {
            XCTAssertTrue(message.contains("model formatting issue"))
            XCTAssertTrue(message.contains("Preferences > Providers"))
        } else {
            XCTFail("Expected formatting error guidance, got \(result)")
        }
    }

    func test_conversationStart_withProviderConfigIssue_returnsActionableGuidance() async throws {
        let failingLLM = AgentLoopMockFailingLLMService()
        let failingGenerator = StructuredGenerator(llm: failingLLM)
        let loop = AgentLoop(
            maxStepsPerTurn: 2,
            maxToolCallsPerTurn: 1,
            maxTokensPerTurn: 256,
            structuredGenerator: failingGenerator,
            toolHost: .shared,
            toolRegistry: self.toolRegistry,
            conversationManager: ConversationManager.makeTestInstance(maxContextTokens: 2000)
        )

        let result = try await loop.process(userText: "Test provider setup issue")

        if case .error(let message) = result {
            XCTAssertTrue(message.contains("Preferences > Providers"))
        } else {
            XCTFail("Expected error result with actionable guidance")
        }
    }

    func test_conversationStart_withUnavailableModelError_returnsActionableGuidance() async throws {
        let failingLLM = AgentLoopMockModelUnavailableLLMService()
        let failingGenerator = StructuredGenerator(llm: failingLLM)
        let loop = AgentLoop(
            maxStepsPerTurn: 2,
            maxToolCallsPerTurn: 1,
            maxTokensPerTurn: 256,
            structuredGenerator: failingGenerator,
            toolHost: .shared,
            toolRegistry: self.toolRegistry,
            conversationManager: ConversationManager.makeTestInstance(maxContextTokens: 2000)
        )

        let result = try await loop.process(userText: "Test unavailable model")

        if case .error(let message) = result {
            XCTAssertTrue(message.contains("model is unavailable"))
            XCTAssertTrue(message.contains("Preferences > Providers"))
        } else {
            XCTFail("Expected error result with model guidance")
        }
    }

    func test_conversationStart_withRequestShapeError_returnsActionableGuidance() async throws {
        let failingLLM = AgentLoopMockRequestShapeRejectedLLMService()
        let failingGenerator = StructuredGenerator(llm: failingLLM)
        let loop = AgentLoop(
            maxStepsPerTurn: 2,
            maxToolCallsPerTurn: 1,
            maxTokensPerTurn: 256,
            structuredGenerator: failingGenerator,
            toolHost: .shared,
            toolRegistry: self.toolRegistry,
            conversationManager: ConversationManager.makeTestInstance(maxContextTokens: 2000)
        )

        let result = try await loop.process(userText: "Test request shape rejection")

        if case .error(let message) = result {
            XCTAssertTrue(message.contains("structured request format"))
            XCTAssertTrue(message.contains("Preferences > Providers"))
        } else {
            XCTFail("Expected error result with request-shape guidance")
        }
    }
    
    // MARK: - Follow-up Tests
    
    func test_executeConfirmedTool_executesTool() async throws {
        // Given: A registered mutate tool (register to shared since ToolHost uses shared)
        await ToolRegistry.shared.register(AgentLoopMockMutateTool(name: "test.create", result: "Created successfully"))
        
        // First, start a session
        await mockLLM.setResponses([
            """
            {"type": "proposal", "summary": "Create", "tool": "test.create", "args": {}}
            """
        ])
        _ = try await agentLoop.process(userText: "Create something")
        
        // When: Execute the confirmed tool
        let result = try await agentLoop.executeConfirmedTool(
            tool: "test.create",
            args: [:]
        )
        
        // Then: Should return success
        XCTAssertEqual(result.humanSummary, "Created successfully")
        
        // Cleanup
        await ToolRegistry.shared.clear()
    }
    
    func test_generateFollowUp_returnsResponse() async throws {
        // Given: A started session with tool result in context
        await mockLLM.setResponses([
            """
            {"type": "response", "text": "Initial"}
            """,
            """
            {"type": "response", "text": "Follow-up response"}
            """
        ])
        
        _ = try await agentLoop.process(userText: "Start")
        
        // When: Generate follow-up
        let followUp = try await agentLoop.generateFollowUp()
        
        // Then: Should return the follow-up text
        XCTAssertEqual(followUp, "Follow-up response")
    }
    
    // MARK: - Session Tests
    
    func test_startSession_setsSessionActive() async throws {
        // Given: A new agent loop
        let isActiveBefore = await agentLoop.isSessionActive()
        XCTAssertFalse(isActiveBefore, "Session should not be active before start")
        
        // When: Start a session
        await agentLoop.startSession()
        
        // Then: Session should be active
        let isActiveAfter = await agentLoop.isSessionActive()
        XCTAssertTrue(isActiveAfter, "Session should be active after start")
    }
    
    func test_endSession_clearsSessionActive() async throws {
        // Given: An active session
        await agentLoop.startSession()
        let isActiveBefore = await agentLoop.isSessionActive()
        XCTAssertTrue(isActiveBefore)
        
        // When: End the session
        await agentLoop.endSession()
        
        // Then: Session should not be active
        let isActiveAfter = await agentLoop.isSessionActive()
        XCTAssertFalse(isActiveAfter, "Session should not be active after end")
    }
    
    func test_process_preservesSessionOnFollowUp() async throws {
        // Given: Two responses for multiple turns
        await mockLLM.setResponses([
            """
            {"type": "response", "text": "First response"}
            """,
            """
            {"type": "response", "text": "Second response"}
            """
        ])
        
        // First turn starts session
        let result1 = try await agentLoop.process(userText: "First message")
        if case .response(let text) = result1 {
            XCTAssertEqual(text, "First response")
        } else {
            XCTFail("Expected response")
        }
        
        // Get message count after first turn
        let messagesAfterFirst = await conversationManager.getConversation()
        
        // Second turn should NOT reset conversation (session is active)
        let result2 = try await agentLoop.process(userText: "Second message")
        if case .response(let text) = result2 {
            XCTAssertEqual(text, "Second response")
        } else {
            XCTFail("Expected response")
        }
        
        // Verify conversation has both turns
        let messagesAfterSecond = await conversationManager.getConversation()
        XCTAssertGreaterThan(messagesAfterSecond.count, messagesAfterFirst.count, 
            "Second turn should add messages, not reset")
        XCTAssertTrue(messagesAfterSecond.contains { $0.content == "First message" }, 
            "First message should still be in conversation")
        XCTAssertTrue(messagesAfterSecond.contains { $0.content == "Second message" }, 
            "Second message should be in conversation")
    }
    
    func test_proposal_storesPendingProposal() async throws {
        // Given: LLM returns a proposal
        await mockLLM.setResponses([
            """
            {"type": "proposal", "summary": "Create event", "tool": "calendar.create", "args": {"title": "Test"}}
            """
        ])
        
        // When: Process returns proposal
        let result = try await agentLoop.process(userText: "Create event")
        
        guard case .proposal = result else {
            XCTFail("Expected proposal result")
            return
        }
        
        // Then: Pending proposal should be stored
        let pendingProposal = await agentLoop.getPendingProposal()
        XCTAssertNotNil(pendingProposal, "Pending proposal should be stored")
        XCTAssertEqual(pendingProposal?.tool, "calendar.create")
        XCTAssertEqual(pendingProposal?.summary, "Create event")
    }
    
    func test_clearPendingProposal_removesPending() async throws {
        // Given: A stored pending proposal
        await mockLLM.setResponses([
            """
            {"type": "proposal", "summary": "Create event", "tool": "calendar.create", "args": {}}
            """
        ])
        _ = try await agentLoop.process(userText: "Create event")
        
        let proposalBefore = await agentLoop.getPendingProposal()
        XCTAssertNotNil(proposalBefore)
        
        // When: Clear pending proposal
        await agentLoop.clearPendingProposal()
        
        // Then: No pending proposal
        let proposalAfter = await agentLoop.getPendingProposal()
        XCTAssertNil(proposalAfter, "Pending proposal should be cleared")
    }
}
