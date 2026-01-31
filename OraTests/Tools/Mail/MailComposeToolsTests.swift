//
//  MailComposeToolsTests.swift
//  OraTests
//
//  Tests for Mail compose tools
//

import XCTest
@testable import Ora

final class MailComposeToolsTests: XCTestCase {

    // MARK: - Schema Tests

    func test_createDraftTool_schema() {
        let tool = MailCreateDraftTool()
        XCTAssertEqual(tool.name, "mail.create_draft")
        XCTAssertEqual(tool.kind, .mutate)
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["to", "subject", "body"])
        XCTAssertNotNil(tool.schema.parameters["to"])
        XCTAssertNotNil(tool.schema.parameters["subject"])
        XCTAssertNotNil(tool.schema.parameters["body"])
        XCTAssertNotNil(tool.schema.parameters["cc"])
        XCTAssertNotNil(tool.schema.parameters["bcc"])
        XCTAssertNotNil(tool.schema.parameters["account"])
        XCTAssertTrue(tool.schema.requiresConfirmation)
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
        XCTAssertNotNil(tool.schema.parameters["cc"])
        XCTAssertNotNil(tool.schema.parameters["bcc"])
        XCTAssertNotNil(tool.schema.parameters["account"])
        XCTAssertTrue(tool.schema.requiresConfirmation)
    }

    func test_openDraftTool_schema() {
        let tool = MailOpenDraftTool()
        XCTAssertEqual(tool.name, "mail.open_draft")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["draft_id"])
        XCTAssertNotNil(tool.schema.parameters["draft_id"])
        XCTAssertFalse(tool.schema.requiresConfirmation)
    }

    // MARK: - Registration Tests

    func test_mailToolsRegistered() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        let createDraft = await ToolRegistry.shared.tool(named: "mail.create_draft")
        let send = await ToolRegistry.shared.tool(named: "mail.send")
        let openDraft = await ToolRegistry.shared.tool(named: "mail.open_draft")

        XCTAssertNotNil(createDraft)
        XCTAssertNotNil(send)
        XCTAssertNotNil(openDraft)
    }

    // MARK: - Validation Tests

    func test_createDraftTool_validate_requiresFields() {
        let tool = MailCreateDraftTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: [
            "to": .string("a@example.com")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: [
            "to": .string("a@example.com"),
            "subject": .string("Hi")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_createDraftTool_validate_acceptsValidArgs() {
        let tool = MailCreateDraftTool()
        XCTAssertNoThrow(try tool.validate(args: [
            "to": .string("a@example.com"),
            "subject": .string("Hello"),
            "body": .string("Hi there")
        ]))
    }

    func test_sendTool_validate_requiresFields() {
        let tool = MailSendTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: [
            "to": .string("a@example.com"),
            "subject": .string("Hi")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_sendTool_validate_rejectsEmptyTo() {
        let tool = MailSendTool()
        XCTAssertThrowsError(try tool.validate(args: [
            "to": .string(""),
            "subject": .string("Hi"),
            "body": .string("Hello")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_openDraftTool_validate_requiresDraftId() {
        let tool = MailOpenDraftTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: [
            "draft_id": .string("")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    // MARK: - Execution Tests

    func test_createDraft_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"draft_id": "draft-123", "subject": "Test Subject"}}
        """
        let runner = MailMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MailCreateDraftTool(runner: runner)

        let result = try await tool.execute(args: [
            "to": .string("a@example.com"),
            "subject": .string("Test Subject"),
            "body": .string("Hello world")
        ])

        XCTAssertEqual(result.humanSummary, "Created draft: 'Test Subject'.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["draft_id"]?.stringValue, "draft-123")
            XCTAssertEqual(dict["subject"]?.stringValue, "Test Subject")
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("on run argv") ?? false)
        XCTAssertTrue(script?.contains("make new outgoing message") ?? false)
        XCTAssertTrue(script?.contains("save newMsg") ?? false)

        let args = await runner.lastArguments
        XCTAssertEqual(args?[0], "a@example.com")
        XCTAssertEqual(args?[1], "Test Subject")
        XCTAssertEqual(args?[2], "Hello world")

        let config = await runner.lastConfig
        XCTAssertTrue(config?.expectsJSON ?? false)
    }

    func test_createDraft_execute_passesOptionalFields() async throws {
        let stdout = """
        {"success": true, "data": {"draft_id": "draft-456", "subject": "CC Test"}}
        """
        let runner = MailMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MailCreateDraftTool(runner: runner)

        _ = try await tool.execute(args: [
            "to": .string("a@example.com"),
            "subject": .string("CC Test"),
            "body": .string("Body"),
            "cc": .string("b@example.com"),
            "bcc": .string("c@example.com"),
            "account": .string("Work")
        ])

        let args = await runner.lastArguments
        XCTAssertEqual(args?[3], "b@example.com")
        XCTAssertEqual(args?[4], "c@example.com")
        XCTAssertEqual(args?[5], "Work")
    }

    func test_send_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"subject": "Hello", "to": "a@example.com"}}
        """
        let runner = MailMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MailSendTool(runner: runner)

        let result = try await tool.execute(args: [
            "to": .string("a@example.com"),
            "subject": .string("Hello"),
            "body": .string("Hi there")
        ])

        XCTAssertEqual(result.humanSummary, "Sent email to a@example.com: 'Hello'.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["subject"]?.stringValue, "Hello")
            XCTAssertEqual(dict["to"]?.stringValue, "a@example.com")
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("on run argv") ?? false)
        XCTAssertTrue(script?.contains("send newMsg") ?? false)

        let args = await runner.lastArguments
        XCTAssertEqual(args?[0], "a@example.com")
        XCTAssertEqual(args?[1], "Hello")
        XCTAssertEqual(args?[2], "Hi there")

        let config = await runner.lastConfig
        XCTAssertTrue(config?.expectsJSON ?? false)
    }

    func test_openDraft_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"draft_id": "draft-789", "subject": "My Draft"}}
        """
        let runner = MailMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = MailOpenDraftTool(runner: runner)

        let result = try await tool.execute(args: [
            "draft_id": .string("draft-789")
        ])

        XCTAssertEqual(result.humanSummary, "Opened draft: 'My Draft'.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["draft_id"]?.stringValue, "draft-789")
            XCTAssertEqual(dict["subject"]?.stringValue, "My Draft")
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("on run argv") ?? false)
        XCTAssertTrue(script?.contains("open targetMsg") ?? false)

        let args = await runner.lastArguments
        XCTAssertEqual(args ?? [], ["draft-789"])
    }

    // MARK: - Error Handling Tests

    func test_parseEnvelope_mapsPermissionDenied() {
        let stdout = """
        {"success": false, "error": "Not authorized to send Apple events to Mail.", "code": -1743}
        """
        let result = Self.makeResult(stdout: stdout)

        XCTAssertThrowsError(try MailAppleScript.parseEnvelope(result)) { error in
            XCTAssertEqual(error as? MailToolError, .permissionDenied)
        }
    }

    func test_parseEnvelope_mapsAccountNotFound() {
        let stdout = """
        {"success": false, "error": "Account not found: Personal", "code": 1001}
        """
        let result = Self.makeResult(stdout: stdout)

        XCTAssertThrowsError(try MailAppleScript.parseEnvelope(result)) { error in
            XCTAssertEqual(error as? MailToolError, .accountNotFound("Account not found: Personal"))
        }
    }

    func test_parseEnvelope_mapsDraftNotFound() {
        let stdout = """
        {"success": false, "error": "Draft not found: bad-id", "code": 1003}
        """
        let result = Self.makeResult(stdout: stdout)

        XCTAssertThrowsError(try MailAppleScript.parseEnvelope(result)) { error in
            XCTAssertEqual(error as? MailToolError, .scriptFailed("Draft not found: bad-id"))
        }
    }

    func test_permissionDeniedError_hasRemediation() {
        let description = MailToolError.permissionDenied.localizedDescription
        XCTAssertTrue(description.contains("System Settings"))
        XCTAssertTrue(description.contains("Automation"))
    }

    func test_createDraft_execute_mapsAppleScriptError() async {
        let runner = MailMockAppleScriptRunner(result: .failure(
            AppleScriptError.permissionDenied(app: "Mail", errorNumber: -1743, rawMessage: "Not permitted")
        ))
        let tool = MailCreateDraftTool(runner: runner)

        do {
            _ = try await tool.execute(args: [
                "to": .string("a@example.com"),
                "subject": .string("Test"),
                "body": .string("Body")
            ])
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? MailToolError, .permissionDenied)
        }
    }

    func test_send_execute_mapsAppleScriptError() async {
        let runner = MailMockAppleScriptRunner(result: .failure(
            AppleScriptError.timeout(seconds: 10)
        ))
        let tool = MailSendTool(runner: runner)

        do {
            _ = try await tool.execute(args: [
                "to": .string("a@example.com"),
                "subject": .string("Test"),
                "body": .string("Body")
            ])
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error as? MailToolError, .scriptFailed("Script timed out after 10 seconds."))
        }
    }

    // MARK: - Script Safety Tests

    func test_createDraftScript_usesArgv() {
        let script = MailAppleScript.createDraftScript()
        XCTAssertTrue(script.contains("on run argv"))
        XCTAssertTrue(script.contains("item 1 of argv"))
        XCTAssertTrue(script.contains("item 2 of argv"))
        XCTAssertTrue(script.contains("item 3 of argv"))
        // Script must not contain Swift string interpolation markers
        XCTAssertFalse(script.contains("\\("))
    }

    func test_sendScript_usesArgv() {
        let script = MailAppleScript.sendScript()
        XCTAssertTrue(script.contains("on run argv"))
        XCTAssertTrue(script.contains("item 1 of argv"))
        XCTAssertTrue(script.contains("send newMsg"))
        XCTAssertFalse(script.contains("\\("))
    }

    func test_openDraftScript_usesArgv() {
        let script = MailAppleScript.openDraftScript()
        XCTAssertTrue(script.contains("on run argv"))
        XCTAssertTrue(script.contains("item 1 of argv"))
        XCTAssertTrue(script.contains("open targetMsg"))
        XCTAssertFalse(script.contains("\\("))
    }

    func test_scripts_areAsciiOnly() {
        let scripts = [
            MailAppleScript.createDraftScript(),
            MailAppleScript.sendScript(),
            MailAppleScript.openDraftScript()
        ]
        for script in scripts {
            for scalar in script.unicodeScalars {
                XCTAssertTrue(
                    scalar.value < 128,
                    "Non-ASCII character found: U+\(String(scalar.value, radix: 16)) in script"
                )
            }
        }
    }

    func test_scripts_containJsonEscape() {
        let scripts = [
            MailAppleScript.createDraftScript(),
            MailAppleScript.sendScript(),
            MailAppleScript.openDraftScript()
        ]
        for script in scripts {
            XCTAssertTrue(script.contains("json_escape"), "Script should include json_escape handler")
            XCTAssertTrue(script.contains("replace_chars"), "Script should include replace_chars handler")
        }
    }

    // MARK: - Helpers

    private static func makeResult(stdout: String) -> AppleScriptResult {
        AppleScriptResult(stdout: stdout, json: nil, duration: 0)
    }
}

// MARK: - Mock AppleScriptRunner

actor MailMockAppleScriptRunner: AppleScriptRunning {
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
