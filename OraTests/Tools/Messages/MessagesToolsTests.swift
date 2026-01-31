//
//  MessagesToolsTests.swift
//  OraTests
//
//  Tests for Messages tools
//

import XCTest
@testable import Ora

final class MessagesToolsTests: XCTestCase {

    func test_sendTool_schema() {
        let tool = MessagesSendTool()
        XCTAssertEqual(tool.name, "messages.send")
        XCTAssertEqual(tool.kind, .mutate)
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["handle", "message"])
        XCTAssertNotNil(tool.schema.parameters["handle"])
        XCTAssertNotNil(tool.schema.parameters["message"])
        XCTAssertNotNil(tool.schema.parameters["service"])
        XCTAssertTrue(tool.schema.requiresConfirmation)
    }

    func test_openChatTool_schema() {
        let tool = MessagesOpenChatTool()
        XCTAssertEqual(tool.name, "messages.open_chat")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["handle"])
        XCTAssertNotNil(tool.schema.parameters["handle"])
        XCTAssertNotNil(tool.schema.parameters["service"])
        XCTAssertFalse(tool.schema.requiresConfirmation)
    }

    func test_messagesToolsRegistered() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        let send = await ToolRegistry.shared.tool(named: "messages.send")
        let open = await ToolRegistry.shared.tool(named: "messages.open_chat")

        XCTAssertNotNil(send)
        XCTAssertNotNil(open)
    }

    func test_sendTool_validate_requiresFields() {
        let tool = MessagesSendTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: ["handle": .string("a@example.com")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_openChatTool_validate_requiresHandle() {
        let tool = MessagesOpenChatTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_send_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"handle": "a@example.com", "message": "Hello", "service": "iMessage"}}
        """
        let runner = MessagesMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MessagesSendTool(runner: runner)

        let result = try await tool.execute(args: [
            "handle": .string("a@example.com"),
            "message": .string("Hello")
        ])

        XCTAssertEqual(result.humanSummary, "Sent message to a@example.com: 'Hello'.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["handle"]?.stringValue, "a@example.com")
            XCTAssertEqual(dict["message"]?.stringValue, "Hello")
            XCTAssertEqual(dict["service"]?.stringValue, "iMessage")
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("on run argv") ?? false)
        XCTAssertTrue(script?.contains("send messageText to targetParticipant") ?? false)

        let args = await runner.lastArguments
        XCTAssertEqual(args ?? [], ["a@example.com", "Hello", ""])

        let config = await runner.lastConfig
        XCTAssertTrue(config?.expectsJSON ?? false)
    }

    func test_openChat_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"handle": "+15551234567", "chat_id": "chat-123", "service": "SMS"}}
        """
        let runner = MessagesMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MessagesOpenChatTool(runner: runner)

        let result = try await tool.execute(args: [
            "handle": .string("+15551234567"),
            "service": .string("SMS")
        ])

        XCTAssertEqual(result.humanSummary, "Opened chat with +15551234567.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["handle"]?.stringValue, "+15551234567")
            XCTAssertEqual(dict["chat_id"]?.stringValue, "chat-123")
            XCTAssertEqual(dict["service"]?.stringValue, "SMS")
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("on run argv") ?? false)
        XCTAssertTrue(script?.contains("make new chat") ?? false)

        let args = await runner.lastArguments
        XCTAssertEqual(args ?? [], ["+15551234567", "SMS"])
    }

    func test_parseEnvelope_mapsPermissionDenied() {
        let stdout = """
        {"success": false, "error": "Not authorized to send Apple events to Messages.", "code": -1743}
        """
        let result = Self.makeResult(stdout: stdout)

        XCTAssertThrowsError(try MessagesAppleScript.parseEnvelope(result)) { error in
            XCTAssertEqual(error as? MessagesToolError, .permissionDenied)
        }
    }

    func test_permissionDeniedError_hasRemediation() {
        let description = MessagesToolError.permissionDenied.localizedDescription
        XCTAssertTrue(description.contains("System Settings"))
        XCTAssertTrue(description.contains("Automation"))
    }

    private static func makeResult(stdout: String) -> AppleScriptResult {
        AppleScriptResult(stdout: stdout, json: nil, duration: 0)
    }
}

// MARK: - Mock AppleScriptRunner

actor MessagesMockAppleScriptRunner: AppleScriptRunning {
    private(set) var lastScript: String?
    private(set) var lastConfig: AppleScriptConfig?
    private(set) var lastArguments: [String]?

    private let result: Result<AppleScriptResult, Error>

    init(result: Result<AppleScriptResult, Error>) {
        self.result = result
    }

    func execute(script: String, config: AppleScriptConfig) async throws -> AppleScriptResult {
        self.lastScript = script
        self.lastConfig = config
        self.lastArguments = nil
        return try result.get()
    }

    func execute(script: String, arguments: [String], config: AppleScriptConfig) async throws -> AppleScriptResult {
        self.lastScript = script
        self.lastConfig = config
        self.lastArguments = arguments
        return try result.get()
    }
}
