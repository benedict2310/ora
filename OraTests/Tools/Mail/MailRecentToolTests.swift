//
//  MailRecentToolTests.swift
//  OraTests
//
//  Tests for Mail recent tool
//

import XCTest
@testable import Ora

final class MailRecentToolTests: XCTestCase {

    func test_recent_returnsHeadersOnly() async throws {
        // Given
        let stdout = """
        {"success": true, "data": [{"message_id": "<id-1>", "subject": "Subject", "from": "John", "date": "2026-02-01", "mailbox": "Inbox", "content": "secret"}]}
        """
        let runner = MailRecentMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailRecentTool(runner: runner)

        // When
        let result = try await tool.execute(args: [:])

        // Then
        guard case .array(let items) = result.json else {
            return XCTFail("Expected array result")
        }
        XCTAssertEqual(items.count, 1)

        guard case .object(let dict) = items[0] else {
            return XCTFail("Expected object item")
        }
        XCTAssertNil(dict["content"])
        XCTAssertEqual(dict["subject"]?.stringValue, "Subject")
        XCTAssertEqual(dict["from"]?.stringValue, "John")
    }

    func test_recent_accountFieldInResults() async throws {
        // Given
        let stdout = """
        {"success": true, "data": [{"message_id": "<id-1>", "subject": "Subject", "from": "John", "date": "2026-02-01", "mailbox": "Inbox", "account": "Work"}]}
        """
        let runner = MailRecentMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailRecentTool(runner: runner)

        // When
        let result = try await tool.execute(args: [:])

        // Then
        guard case .array(let items) = result.json,
              case .object(let dict) = items.first else {
            return XCTFail("Expected array with object")
        }
        XCTAssertEqual(dict["account"]?.stringValue, "Work")
    }

    func test_recent_noAccountQueriesAllAccounts() {
        let script = MailAppleScript.recentMessagesScript()
        XCTAssertTrue(script.contains("set accountsToSearch to every account"))
        XCTAssertTrue(script.contains("repeat with theAccount in accountsToSearch"))
    }

    func test_recent_returnsMessageId() async throws {
        // Given
        let stdout = """
        {"success": true, "data": [{"message_id": "<id-123>", "subject": "Hello", "from": "Alice", "date": "2026-02-01", "mailbox": "Inbox"}]}
        """
        let runner = MailRecentMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailRecentTool(runner: runner)

        // When
        let result = try await tool.execute(args: [:])

        // Then
        guard case .array(let items) = result.json,
              case .object(let dict) = items.first else {
            return XCTFail("Expected array with object")
        }
        XCTAssertEqual(dict["message_id"]?.stringValue, "<id-123>")
    }

    func test_recent_respectsLimit() async throws {
        // Given
        let stdout = """
        {"success": true, "data": [
            {"message_id": "<id-1>", "subject": "One", "from": "A", "date": "2026-02-01", "mailbox": "Inbox"},
            {"message_id": "<id-2>", "subject": "Two", "from": "B", "date": "2026-02-01", "mailbox": "Inbox"},
            {"message_id": "<id-3>", "subject": "Three", "from": "C", "date": "2026-02-01", "mailbox": "Inbox"}
        ]}
        """
        let runner = MailRecentMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailRecentTool(runner: runner)

        // When
        let result = try await tool.execute(args: [
            "limit": .number(2)
        ])

        // Then
        let lastArguments = await runner.lastArguments
        XCTAssertEqual(lastArguments?[2], "2")

        guard case .array(let items) = result.json else {
            return XCTFail("Expected array result")
        }
        XCTAssertEqual(items.count, 2)
    }

    func test_recent_defaultsLimit() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = MailRecentMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [:])

        // Then
        let lastArguments = await runner.lastArguments
        XCTAssertEqual(lastArguments?[2], "10")
    }

    func test_recent_clampsLimit() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = MailRecentMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [
            "limit": .number(100)
        ])

        // Then
        let lastArguments = await runner.lastArguments
        XCTAssertEqual(lastArguments?[2], "50")
    }

    func test_recent_passesMailboxFilter() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = MailRecentMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [
            "mailbox": .string("Inbox")
        ])

        // Then
        let lastArguments = await runner.lastArguments
        XCTAssertEqual(lastArguments?[0], "Inbox")
    }

    func test_recent_passesAccountFilter() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = MailRecentMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [
            "account": .string("Work")
        ])

        // Then
        let lastArguments = await runner.lastArguments
        XCTAssertEqual(lastArguments?[1], "Work")
    }

    func test_recent_noRequiredParams() {
        // Given
        let tool = MailRecentTool()

        // When / Then
        XCTAssertNoThrow(try tool.validate(args: [:]))
    }

    // MARK: - Helpers

    private static func makeResult(stdout: String) -> AppleScriptResult {
        AppleScriptResult(stdout: stdout, json: nil, duration: 0)
    }
}

// MARK: - Mock AppleScriptRunner

actor MailRecentMockAppleScriptRunner: AppleScriptRunning {
    private var results: [Result<AppleScriptResult, Error>]
    private(set) var scripts: [String] = []
    private(set) var argumentsList: [[String]] = []
    private(set) var configs: [AppleScriptConfig] = []

    init(results: [Result<AppleScriptResult, Error>]) {
        self.results = results
    }

    var lastArguments: [String]? {
        self.argumentsList.last
    }

    func execute(script: String, config: AppleScriptConfig) async throws -> AppleScriptResult {
        self.scripts.append(script)
        self.configs.append(config)
        guard !self.results.isEmpty else {
            throw AppleScriptError.invalidOutput(rawOutput: "No results")
        }
        return try self.results.removeFirst().get()
    }

    func execute(script: String, arguments: [String], config: AppleScriptConfig) async throws -> AppleScriptResult {
        self.scripts.append(script)
        self.argumentsList.append(arguments)
        self.configs.append(config)
        guard !self.results.isEmpty else {
            throw AppleScriptError.invalidOutput(rawOutput: "No results")
        }
        return try self.results.removeFirst().get()
    }
}
