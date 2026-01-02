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
            requiredParameters: []
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
            requiredParameters: []
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
}
