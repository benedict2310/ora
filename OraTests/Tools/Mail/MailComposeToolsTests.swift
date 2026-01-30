//
//  MailComposeToolsTests.swift
//  OraTests
//
//  Tests for Mail compose tools
//

import XCTest
@testable import Ora

final class MailComposeToolsTests: XCTestCase {

    func test_createDraftTool_schema() {
        let tool = MailCreateDraftTool()
        XCTAssertEqual(tool.name, "mail.create_draft")
        XCTAssertEqual(tool.kind, .mutate)
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["to", "subject", "body"])
        XCTAssertNotNil(tool.schema.parameters["to"])
        XCTAssertNotNil(tool.schema.parameters["cc"])
        XCTAssertNotNil(tool.schema.parameters["bcc"])
        XCTAssertNotNil(tool.schema.parameters["subject"])
        XCTAssertNotNil(tool.schema.parameters["body"])
        XCTAssertNotNil(tool.schema.parameters["account"])
    }

    func test_sendTool_schema() {
        let tool = MailSendTool()
        XCTAssertEqual(tool.name, "mail.send")
        XCTAssertEqual(tool.kind, .mutate)
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["to", "subject", "body"])
        XCTAssertNotNil(tool.schema.parameters["to"])
        XCTAssertNotNil(tool.schema.parameters["subject"])
        XCTAssertNotNil(tool.schema.parameters["body"])
    }

    func test_openDraftTool_schema() {
        let tool = MailOpenDraftTool()
        XCTAssertEqual(tool.name, "mail.open_draft")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["draft_id"])
        XCTAssertNotNil(tool.schema.parameters["draft_id"])
    }

    func test_mailToolsRegistered() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        let createDraft = await ToolRegistry.shared.tool(named: "mail.create_draft")
        let send = await ToolRegistry.shared.tool(named: "mail.send")
        let open = await ToolRegistry.shared.tool(named: "mail.open_draft")

        XCTAssertNotNil(createDraft)
        XCTAssertNotNil(send)
        XCTAssertNotNil(open)
    }

    func test_createDraftTool_validate_requiresFields() {
        let tool = MailCreateDraftTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: ["to": .string("a@example.com")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: ["to": .string("a@example.com"), "subject": .string("Hi")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_sendTool_validate_requiresFields() {
        let tool = MailSendTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: ["to": .string("a@example.com")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: ["to": .string("a@example.com"), "subject": .string("Hi")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_openDraftTool_validate_requiresDraftId() {
        let tool = MailOpenDraftTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_createDraft_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"draft_id": "draft-123", "subject": "Hello", "to": ["a@example.com"], "cc": [], "bcc": [], "account": "iCloud"}}
        """
        let runner = MailMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MailCreateDraftTool(runner: runner)

        let result = try await tool.execute(args: [
            "to": .string("a@example.com"),
            "subject": .string("Hello"),
            "body": .string("Body"),
            "account": .string("iCloud")
        ])

        XCTAssertEqual(result.humanSummary, "Created draft to a@example.com with subject 'Hello'.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["draft_id"]?.stringValue, "draft-123")
            XCTAssertEqual(dict["subject"]?.stringValue, "Hello")
            XCTAssertEqual(dict["account"]?.stringValue, "iCloud")
            if case .array(let toList) = dict["to"] {
                XCTAssertEqual(toList.first?.stringValue, "a@example.com")
            } else {
                XCTFail("Expected to array")
            }
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set toText to \"a@example.com\"") ?? false)
        XCTAssertTrue(script?.contains("set subjectText to \"Hello\"") ?? false)
        XCTAssertTrue(script?.contains("save newMessage") ?? false)

        let config = await runner.lastConfig
        XCTAssertTrue(config?.expectsJSON ?? false)
    }

    func test_send_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"message_id": "msg-456", "subject": "Hi", "to": ["b@example.com"], "sent": true}}
        """
        let runner = MailMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MailSendTool(runner: runner)

        let result = try await tool.execute(args: [
            "to": .string("b@example.com"),
            "subject": .string("Hi"),
            "body": .string("Body")
        ])

        XCTAssertEqual(result.humanSummary, "Sent email to b@example.com with subject 'Hi'.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["message_id"]?.stringValue, "msg-456")
            XCTAssertEqual(dict["subject"]?.stringValue, "Hi")
            XCTAssertEqual(dict["sent"]?.boolValue, true)
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("send newMessage") ?? false)
    }

    func test_openDraft_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"draft_id": "draft-123", "subject": "Hello"}}
        """
        let runner = MailMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MailOpenDraftTool(runner: runner)

        let result = try await tool.execute(args: [
            "draft_id": .string("draft-123")
        ])

        XCTAssertEqual(result.humanSummary, "Opened draft 'Hello'.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["draft_id"]?.stringValue, "draft-123")
            XCTAssertEqual(dict["subject"]?.stringValue, "Hello")
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set draftId to \"draft-123\"") ?? false)
    }

    func test_parseEnvelope_mapsPermissionDenied() {
        let stdout = """
        {"success": false, "error": "Not authorized to send Apple events to Mail.", "code": -1743}
        """
        let result = Self.makeResult(stdout: stdout)

        XCTAssertThrowsError(try MailAppleScript.parseEnvelope(result)) { error in
            XCTAssertEqual(error as? MailToolError, .permissionDenied)
        }
    }

    func test_parseEnvelope_unescapesEscapedJSON() throws {
        let stdout = """
        {\\\"success\\\": true, \\\"data\\\": {\\\"draft_id\\\": \\\"draft-123\\\", \\\"subject\\\": \\\"Hello\\\"}}
        """
        let result = Self.makeResult(stdout: stdout)

        let data = try MailAppleScript.parseEnvelope(result)

        if case .object(let dict) = data {
            XCTAssertEqual(dict["draft_id"]?.stringValue, "draft-123")
            XCTAssertEqual(dict["subject"]?.stringValue, "Hello")
        } else {
            XCTFail("Expected data object")
        }
    }

    func test_permissionDeniedError_hasRemediation() {
        let description = MailToolError.permissionDenied.localizedDescription
        XCTAssertTrue(description.contains("System Settings"))
        XCTAssertTrue(description.contains("Automation"))
    }

    private static func makeResult(stdout: String) -> AppleScriptResult {
        AppleScriptResult(stdout: stdout, json: nil, duration: 0)
    }
}

// MARK: - Mock AppleScriptRunner

actor MailMockAppleScriptRunner: AppleScriptRunning {
    private(set) var lastScript: String?
    private(set) var lastConfig: AppleScriptConfig?

    private let result: Result<AppleScriptResult, Error>

    init(result: Result<AppleScriptResult, Error>) {
        self.result = result
    }

    func execute(script: String, config: AppleScriptConfig) async throws -> AppleScriptResult {
        self.lastScript = script
        self.lastConfig = config
        return try result.get()
    }
}
