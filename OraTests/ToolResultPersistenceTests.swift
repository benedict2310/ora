//
//  ToolResultPersistenceTests.swift
//  OraTests
//
//  Tests for persisted tool result transcript messages.
//

import XCTest
@testable import Ora

actor SessionBackedPersistenceSink: AgentLoopPersistenceSink {
    private let persistenceManager: PersistenceManager

    init(persistenceManager: PersistenceManager) {
        self.persistenceManager = persistenceManager
    }

    func appendMessage(role: Session.Message.Role, content: String) async throws {
        await MainActor.run {
            _ = self.persistenceManager.appendMessage(role: role, content: content)
        }
    }

    func persistedMessages() async -> [Session.Message] {
        return await MainActor.run {
            self.persistenceManager.currentSession().messages
        }
    }
}

actor ToolResultPersistenceMockLLMService: LLMServicing {
    private let responses: [String]
    private var responseIndex: Int = 0

    init(responses: [String]) {
        self.responses = responses
    }

    func warmup() async throws {}
    func prepare() async throws {}
    func unload() async {}
    func capabilities() async -> ProviderCapabilities { .textOnly }
    func clearCache() async {}

    func generate(messages: [LLMMessage], maxTokens: Int) async -> AsyncThrowingStream<LLMDelta, Error> {
        let response: String
        if self.responseIndex < self.responses.count {
            response = self.responses[self.responseIndex]
            self.responseIndex += 1
        } else {
            response = #"{"type":"response","text":"Done"}"#
        }

        return AsyncThrowingStream { continuation in
            continuation.yield(.token(response))
            continuation.finish()
        }
    }
}

struct ToolResultPersistenceMockTool: Tool {
    let name: String
    let kind: ToolKind = .read
    let toolSummary: String
    let toolJSON: JSONValue

    var schema: ToolSchema {
        return ToolSchema(
            name: self.name,
            description: "Mock tool for persistence tests",
            parameters: [:],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {}

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        return .success(self.toolJSON, summary: self.toolSummary)
    }
}

@MainActor
final class ToolResultPersistenceTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await ToolRegistry.shared.clear()
        await AuditLogger.shared.clearAll()
    }

    override func tearDown() async throws {
        await ToolRegistry.shared.clear()
        await AuditLogger.shared.clearAll()
        try await super.tearDown()
    }

    func test_toolResultPersistence_successfulToolCall_persistsToolRoleMessage() async throws {
        // Given
        let toolName = "test.lookup"
        let tool = ToolResultPersistenceMockTool(
            name: toolName,
            toolSummary: "Found 3 matching records",
            toolJSON: .object([
                "records": .array([.string("a"), .string("b"), .string("c")])
            ])
        )
        await ToolRegistry.shared.register(tool)

        let persistenceManager = PersistenceManager.createForTesting()
        let persistenceSink = SessionBackedPersistenceSink(persistenceManager: persistenceManager)
        let loop = self.makeLoop(
            responses: [
                #"{"type":"tool_call","tool":"test.lookup","args":{}}"#,
                #"{"type":"response","text":"Done"}"#
            ],
            persistenceSink: persistenceSink
        )

        // When
        _ = try await loop.process(userText: "Look this up")
        let persistedMessages = await persistenceSink.persistedMessages()

        // Then
        let toolMessage = try XCTUnwrap(persistedMessages.first(where: { $0.role == .tool }))
        XCTAssertTrue(toolMessage.content.hasPrefix("[ToolResult: \(toolName)] "))
        XCTAssertTrue(toolMessage.content.contains("Found 3 matching records"))

        let auditID = try XCTUnwrap(self.extractAuditID(from: toolMessage.content))
        XCTAssertNotNil(auditID)
    }

    func test_toolResultPersistence_largeToolOutput_persistsBoundedSummaryOnly() async throws {
        // Given
        let toolName = "test.large"
        let summaryPrefix = String(repeating: "S", count: 560)
        let fullSummary = summaryPrefix + "TAIL-SHOULD-NOT-APPEAR"
        let jsonMarker = "JSON-OUTPUT-SHOULD-NOT-BE-PERSISTED"
        let tool = ToolResultPersistenceMockTool(
            name: toolName,
            toolSummary: fullSummary,
            toolJSON: .object([
                "payload": .string(String(repeating: jsonMarker, count: 20))
            ])
        )
        await ToolRegistry.shared.register(tool)

        let persistenceManager = PersistenceManager.createForTesting()
        let persistenceSink = SessionBackedPersistenceSink(persistenceManager: persistenceManager)
        let loop = self.makeLoop(
            responses: [
                #"{"type":"tool_call","tool":"test.large","args":{}}"#,
                #"{"type":"response","text":"Done"}"#
            ],
            persistenceSink: persistenceSink
        )

        // When
        _ = try await loop.process(userText: "Run large tool")
        let persistedMessages = await persistenceSink.persistedMessages()
        let toolMessage = try XCTUnwrap(persistedMessages.first(where: { $0.role == .tool }))
        let summary = try XCTUnwrap(self.extractSummary(from: toolMessage.content, toolName: toolName))

        // Then
        XCTAssertLessThanOrEqual(summary.count, 500)
        XCTAssertFalse(summary.contains("TAIL-SHOULD-NOT-APPEAR"))
        XCTAssertFalse(toolMessage.content.contains(jsonMarker))
        XCTAssertNotNil(self.extractAuditID(from: toolMessage.content))
    }

    // MARK: - Helpers

    private func makeLoop(
        responses: [String],
        persistenceSink: AgentLoopPersistenceSink
    ) -> AgentLoop {
        return AgentLoop(
            maxStepsPerTurn: 4,
            maxToolCallsPerTurn: 2,
            maxTokensPerTurn: 800,
            structuredGenerator: StructuredGenerator(llm: ToolResultPersistenceMockLLMService(responses: responses)),
            toolHost: .shared,
            toolRegistry: .shared,
            conversationManager: ConversationManager.makeTestInstance(maxContextTokens: 6000),
            persistenceSink: persistenceSink
        )
    }

    private func extractAuditID(from content: String) -> UUID? {
        let marker = "(auditId="
        guard let markerRange = content.range(of: marker),
              content.hasSuffix(")") else {
            return nil
        }

        let uuidStart = markerRange.upperBound
        let uuidEnd = content.index(before: content.endIndex)
        let uuidString = String(content[uuidStart..<uuidEnd])
        return UUID(uuidString: uuidString)
    }

    private func extractSummary(from content: String, toolName: String) -> String? {
        let prefix = "[ToolResult: \(toolName)] "
        let suffix = " (auditId="

        guard content.hasPrefix(prefix),
              let suffixRange = content.range(of: suffix) else {
            return nil
        }

        let start = content.index(content.startIndex, offsetBy: prefix.count)
        return String(content[start..<suffixRange.lowerBound])
    }
}
