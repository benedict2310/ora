//
//  MailSearchToolTests.swift
//  OraTests
//
//  Tests for Mail search/open/list tools
//

import XCTest
@testable import Ora

final class MailSearchToolTests: XCTestCase {

    // MARK: - Search Tests

    func test_search_returnsHeadersOnly() async throws {
        let stdout = """
        {"success": true, "data": [{"message_id": "<id-1>", "subject": "Subject", "from": "John", "date": "2026-02-01", "mailbox": "Inbox", "content": "secret"}]}
        """
        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Subject")
        ])

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

    func test_search_accountFieldInResults() async throws {
        let stdout = """
        {"success": true, "data": [{"message_id": "<id-1>", "subject": "Subject", "from": "John", "date": "2026-02-01", "mailbox": "Inbox", "account": "Work"}]}
        """
        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Subject")
        ])

        guard case .array(let items) = result.json,
              case .object(let dict) = items.first else {
            return XCTFail("Expected array with object")
        }
        XCTAssertEqual(dict["account"]?.stringValue, "Work")
    }

    func test_search_noAccountQueriesAllAccounts() {
        let script = MailAppleScript.searchMessagesScript()
        XCTAssertTrue(script.contains("set accountsToSearch to every account"))
        XCTAssertTrue(script.contains("repeat with theAccount in accountsToSearch"))
    }

    func test_search_normalizesInboxMailboxName() {
        let script = MailAppleScript.searchMessagesScript()
        XCTAssertTrue(script.contains("if mailboxName contains \"inbox\""))
        XCTAssertTrue(script.contains("set mailboxName to \"INBOX\""))
    }

    func test_search_returnsStableMessageId() async throws {
        let stdout = """
        {"success": true, "data": [{"message_id": "<id-123>", "subject": "Hello", "from": "Alice", "date": "2026-02-01", "mailbox": "Inbox"}]}
        """
        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Hello")
        ])

        guard case .array(let items) = result.json,
              case .object(let dict) = items.first else {
            return XCTFail("Expected array with object")
        }

        XCTAssertEqual(dict["message_id"]?.stringValue, "<id-123>")
    }

    func test_search_withAccountFiltersToSingleAccount() async throws {
        let stdout = """
        {"success": true, "data": [{"message_id": "<id-1>", "subject": "Hello", "from": "Alice", "date": "2026-02-01", "mailbox": "Inbox", "account": "Work"}]}
        """
        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailSearchTool(runner: runner)

        _ = try await tool.execute(args: [
            "query": .string("Hello"),
            "account": .string("Work")
        ])

        let lastArguments = await runner.lastArguments
        XCTAssertEqual(lastArguments?[2], "Work")
    }

    func test_search_exactResults_skipFuzzyFallback() async throws {
        let stdout = """
        {"success": true, "data": [{"message_id": "<id-1>", "subject": "Hello", "from": "Alice", "date": "2026-02-01", "mailbox": "Inbox"}]}
        """
        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailSearchTool(runner: runner)

        _ = try await tool.execute(args: [
            "query": .string("Hello")
        ])

        let callCount = await runner.callCount
        XCTAssertEqual(callCount, 1)
    }

    func test_search_fuzzyFallback_findsTypo() async throws {
        let exactStdout = """
        {"success": true, "data": []}
        """
        let recentStdout = """
        {"success": true, "data": [{"message_id": "<id-1>", "subject": "John", "from": "John", "date": "2026-02-01", "mailbox": "Inbox"}]}
        """

        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: exactStdout)),
            .success(Self.makeResult(stdout: recentStdout))
        ])
        let tool = MailSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Jonh")
        ])

        guard case .array(let items) = result.json,
              case .object(let dict) = items.first else {
            return XCTFail("Expected array with object")
        }

        XCTAssertEqual(dict["message_id"]?.stringValue, "<id-1>")
        XCTAssertNotNil(dict["match_score"])
        XCTAssertGreaterThanOrEqual(dict["match_score"]?.numberValue ?? 0.0, 0.8)
    }

    func test_search_fuzzyFallback_respectsThreshold() async throws {
        let exactStdout = """
        {"success": true, "data": []}
        """
        let recentStdout = """
        {"success": true, "data": [{"message_id": "<id-1>", "subject": "Report", "from": "Alice", "date": "2026-02-01", "mailbox": "Inbox"}]}
        """

        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: exactStdout)),
            .success(Self.makeResult(stdout: recentStdout))
        ])
        let tool = MailSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Zebra")
        ])

        guard case .array(let items) = result.json else {
            return XCTFail("Expected array result")
        }
        XCTAssertTrue(items.isEmpty)
    }

    func test_search_fuzzyFallback_sortedByScore() async throws {
        let exactStdout = """
        {"success": true, "data": []}
        """
        let recentStdout = """
        {"success": true, "data": [
            {"message_id": "<id-1>", "subject": "John", "from": "John", "date": "2026-02-01", "mailbox": "Inbox"},
            {"message_id": "<id-2>", "subject": "Johan", "from": "Johan", "date": "2026-02-01", "mailbox": "Inbox"}
        ]}
        """

        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: exactStdout)),
            .success(Self.makeResult(stdout: recentStdout))
        ])
        let tool = MailSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Jonh")
        ])

        guard case .array(let items) = result.json else {
            return XCTFail("Expected array result")
        }
        XCTAssertGreaterThanOrEqual(items.count, 2)

        guard case .object(let first) = items[0],
              case .object(let second) = items[1] else {
            return XCTFail("Expected object items")
        }

        let firstScore = first["match_score"]?.numberValue ?? 0.0
        let secondScore = second["match_score"]?.numberValue ?? 0.0
        XCTAssertGreaterThanOrEqual(firstScore, secondScore)
    }

    func test_search_respectsLimit() async throws {
        let stdout = """
        {"success": true, "data": [
            {"message_id": "<id-1>", "subject": "One", "from": "A", "date": "2026-02-01", "mailbox": "Inbox"},
            {"message_id": "<id-2>", "subject": "Two", "from": "B", "date": "2026-02-01", "mailbox": "Inbox"},
            {"message_id": "<id-3>", "subject": "Three", "from": "C", "date": "2026-02-01", "mailbox": "Inbox"}
        ]}
        """
        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("One"),
            "limit": .number(2)
        ])

        let lastArguments = await runner.lastArguments
        XCTAssertEqual(lastArguments?[3], "2")

        guard case .array(let items) = result.json else {
            return XCTFail("Expected array result")
        }
        XCTAssertEqual(items.count, 2)
    }

    func test_search_handlesPartialFailuresEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"messages": [{"message_id": "<id-1>", "subject": "Hello", "from": "Alice", "date": "2026-02-01", "mailbox": "Inbox", "account": "Work"}], "errors": "Other: timeout"}}
        """
        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Hello")
        ])

        guard case .array(let items) = result.json,
              case .object(let dict) = items.first else {
            return XCTFail("Expected array with object")
        }
        XCTAssertEqual(dict["message_id"]?.stringValue, "<id-1>")
        XCTAssertTrue(result.humanSummary.contains("Some accounts could not be queried."))
    }

    // MARK: - Open/List Tests

    func test_openMessage_validatesId() {
        let tool = MailOpenMessageTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: [
            "message_id": .string("")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_listMailboxes_returnsNames() async throws {
        let stdout = """
        {"success": true, "data": [{"name": "Inbox", "account": "iCloud"}, {"name": "Sent", "account": "iCloud"}]}
        """
        let runner = MailSearchMockAppleScriptRunner(results: [
            .success(Self.makeResult(stdout: stdout))
        ])
        let tool = MailListMailboxesTool(runner: runner)

        let result = try await tool.execute(args: [:])

        guard case .array(let items) = result.json else {
            return XCTFail("Expected array result")
        }
        XCTAssertEqual(items.count, 2)
        guard case .object(let first) = items[0] else {
            return XCTFail("Expected object item")
        }
        XCTAssertEqual(first["name"]?.stringValue, "Inbox")
    }

    // MARK: - Helpers

    private static func makeResult(stdout: String) -> AppleScriptResult {
        AppleScriptResult(stdout: stdout, json: nil, duration: 0)
    }
}

// MARK: - Mock AppleScriptRunner

actor MailSearchMockAppleScriptRunner: AppleScriptRunning {
    private var results: [Result<AppleScriptResult, Error>]
    private(set) var scripts: [String] = []
    private(set) var argumentsList: [[String]] = []
    private(set) var configs: [AppleScriptConfig] = []

    init(results: [Result<AppleScriptResult, Error>]) {
        self.results = results
    }

    var callCount: Int {
        self.scripts.count
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
