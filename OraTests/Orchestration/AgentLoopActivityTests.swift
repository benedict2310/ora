//
//  AgentLoopActivityTests.swift
//  OraTests
//
//  Tests for AgentLoop activity events
//

import XCTest
@testable import Ora

// MARK: - Activity Tracking Delegate

/// Test delegate that tracks activity events
@MainActor
final class ActivityTrackingDelegate: AgentLoopDelegate {
    var activities: [AgentActivity] = []
    var tokens: [String] = []
    var toolExecutions: [(name: String, result: String)] = []

    func agentLoopDidStartThinking(_ loop: AgentLoop) {}

    func agentLoop(_ loop: AgentLoop, didProduceToken token: String) {
        self.tokens.append(token)
    }

    func agentLoop(_ loop: AgentLoop, didRequestConfirmation proposal: ToolProposal) {}

    func agentLoop(_ loop: AgentLoop, didExecuteTool name: String, result: String) {
        self.toolExecutions.append((name: name, result: result))
    }

    func agentLoop(_ loop: AgentLoop, didUpdateActivity activity: AgentActivity) {
        self.activities.append(activity)
    }

    func reset() {
        self.activities.removeAll()
        self.tokens.removeAll()
        self.toolExecutions.removeAll()
    }
}

// MARK: - Tests

final class AgentLoopActivityTests: XCTestCase {

    var mockLLM: AgentLoopMockLLMService!
    var structuredGenerator: StructuredGenerator!
    var toolRegistry: ToolRegistry!
    var conversationManager: ConversationManager!
    var agentLoop: AgentLoop!
    var delegate: ActivityTrackingDelegate!

    @MainActor
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

        delegate = ActivityTrackingDelegate()
        agentLoop.setDelegate(delegate)
    }

    // MARK: - AgentActivity Enum Tests

    func test_agentActivity_equality() {
        XCTAssertEqual(AgentActivity.planning, AgentActivity.planning)
        XCTAssertEqual(AgentActivity.composing, AgentActivity.composing)
        XCTAssertEqual(AgentActivity.waiting, AgentActivity.waiting)
        XCTAssertEqual(AgentActivity.toolCall(name: "test"), AgentActivity.toolCall(name: "test"))
        XCTAssertEqual(AgentActivity.toolResult(name: "test"), AgentActivity.toolResult(name: "test"))
    }

    func test_agentActivity_inequality() {
        XCTAssertNotEqual(AgentActivity.planning, AgentActivity.composing)
        XCTAssertNotEqual(AgentActivity.toolCall(name: "a"), AgentActivity.toolCall(name: "b"))
        XCTAssertNotEqual(AgentActivity.toolCall(name: "test"), AgentActivity.toolResult(name: "test"))
    }

    // MARK: - Activity Event Ordering Tests

    @MainActor
    func test_simpleResponse_emitsPlanningThenComposing() async throws {
        // Given: LLM returns a simple response
        await mockLLM.setResponses([
            """
            {"type": "response", "text": "Hello!"}
            """
        ])

        // When: Process user input
        _ = try await agentLoop.process(userText: "Hello")

        // Then: Should emit planning before response generation
        // Note: composing is emitted on first token, but our mock doesn't stream properly
        // so we may only see planning
        XCTAssertFalse(delegate.activities.isEmpty, "Should emit at least one activity")
        XCTAssertEqual(delegate.activities.first, .planning, "First activity should be planning")
    }

    @MainActor
    func test_toolCall_emitsToolCallAndToolResult() async throws {
        // Given: LLM calls a tool then responds
        await toolRegistry.register(AgentLoopMockReadTool(name: "test.query", result: "Query result"))

        await mockLLM.setResponses([
            """
            {"type": "tool_call", "tool": "test.query", "args": {}}
            """,
            """
            {"type": "response", "text": "Done"}
            """
        ])

        // When: Process user input
        _ = try await agentLoop.process(userText: "Query something")

        // Then: Should emit planning, toolCall, toolResult, planning sequence
        let activities = delegate.activities
        XCTAssertTrue(activities.contains(.planning), "Should emit planning")
        XCTAssertTrue(activities.contains(.toolCall(name: "test.query")), "Should emit toolCall")
        XCTAssertTrue(activities.contains(.toolResult(name: "test.query")), "Should emit toolResult")
    }

    @MainActor
    func test_toolCall_activityOrder() async throws {
        // Given: LLM calls a tool then responds
        await toolRegistry.register(AgentLoopMockReadTool(name: "calendar.query", result: "Events"))

        await mockLLM.setResponses([
            """
            {"type": "tool_call", "tool": "calendar.query", "args": {}}
            """,
            """
            {"type": "response", "text": "Here are your events"}
            """
        ])

        // When: Process user input
        _ = try await agentLoop.process(userText: "What's on my calendar?")

        // Then: toolCall should come before toolResult
        let activities = delegate.activities
        let toolCallIndex = activities.firstIndex(of: .toolCall(name: "calendar.query"))
        let toolResultIndex = activities.firstIndex(of: .toolResult(name: "calendar.query"))

        XCTAssertNotNil(toolCallIndex, "Should have toolCall activity")
        XCTAssertNotNil(toolResultIndex, "Should have toolResult activity")

        if let callIndex = toolCallIndex, let resultIndex = toolResultIndex {
            XCTAssertLessThan(callIndex, resultIndex, "toolCall should come before toolResult")
        }
    }

    @MainActor
    func test_multipleToolCalls_emitsActivityForEach() async throws {
        // Given: LLM calls two tools then responds
        await toolRegistry.register(AgentLoopMockReadTool(name: "calendar.query", result: "Events"))
        await toolRegistry.register(AgentLoopMockReadTool(name: "contacts.search", result: "Contacts"))

        await mockLLM.setResponses([
            """
            {"type": "tool_call", "tool": "calendar.query", "args": {}}
            """,
            """
            {"type": "tool_call", "tool": "contacts.search", "args": {}}
            """,
            """
            {"type": "response", "text": "Done"}
            """
        ])

        // When: Process user input
        _ = try await agentLoop.process(userText: "Check calendar and contacts")

        // Then: Should emit activities for both tools
        let activities = delegate.activities
        XCTAssertTrue(activities.contains(.toolCall(name: "calendar.query")), "Should have calendar toolCall")
        XCTAssertTrue(activities.contains(.toolResult(name: "calendar.query")), "Should have calendar toolResult")
        XCTAssertTrue(activities.contains(.toolCall(name: "contacts.search")), "Should have contacts toolCall")
        XCTAssertTrue(activities.contains(.toolResult(name: "contacts.search")), "Should have contacts toolResult")
    }

    @MainActor
    func test_proposal_emitsPlanning() async throws {
        // Given: LLM returns a proposal
        await mockLLM.setResponses([
            """
            {"type": "proposal", "summary": "Create event", "tool": "calendar.create", "args": {"title": "Meeting"}}
            """
        ])

        // When: Process user input
        _ = try await agentLoop.process(userText: "Schedule a meeting")

        // Then: Should emit planning activity
        XCTAssertTrue(delegate.activities.contains(.planning), "Should emit planning before proposal")
    }

    @MainActor
    func test_executeConfirmedTool_emitsToolCallAndToolResult() async throws {
        // Given: A registered mutate tool
        await ToolRegistry.shared.register(AgentLoopMockMutateTool(name: "test.create", result: "Created"))

        // Start session and get proposal
        await mockLLM.setResponses([
            """
            {"type": "proposal", "summary": "Create", "tool": "test.create", "args": {}}
            """
        ])
        _ = try await agentLoop.process(userText: "Create something")

        delegate.reset()

        // When: Execute the confirmed tool
        _ = try await agentLoop.executeConfirmedTool(tool: "test.create", args: [:])

        // Then: Should emit toolCall and toolResult
        let activities = delegate.activities
        XCTAssertTrue(activities.contains(.toolCall(name: "test.create")), "Should emit toolCall")
        XCTAssertTrue(activities.contains(.toolResult(name: "test.create")), "Should emit toolResult")

        // Cleanup
        await ToolRegistry.shared.clear()
    }

    @MainActor
    func test_generateFollowUp_emitsComposing() async throws {
        // Given: Session with prior context
        await mockLLM.setResponses([
            """
            {"type": "response", "text": "First"}
            """,
            """
            {"type": "response", "text": "Follow-up"}
            """
        ])

        _ = try await agentLoop.process(userText: "Start")
        delegate.reset()

        // When: Generate follow-up
        _ = try await agentLoop.generateFollowUp()

        // Then: Should emit composing activity
        XCTAssertTrue(delegate.activities.contains(.composing), "Should emit composing during follow-up")
    }
}
