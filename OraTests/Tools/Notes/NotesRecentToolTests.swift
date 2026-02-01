//
//  NotesRecentToolTests.swift
//  OraTests
//
//  Tests for Notes recent tool
//

import XCTest
@testable import Ora

final class NotesRecentToolTests: XCTestCase {

    func test_recent_returnsTitleAndFolder() async throws {
        // Given
        let stdout = """
        {"success": true, "data": [{"note_id": "note-1", "title": "Alpha", "folder": "Work", "modification_date": "2026-02-01", "body": "secret"}]}
        """
        let runner = NotesRecentMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesRecentTool(runner: runner)

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
        XCTAssertEqual(dict["note_id"]?.stringValue, "note-1")
        XCTAssertEqual(dict["title"]?.stringValue, "Alpha")
        XCTAssertEqual(dict["folder"]?.stringValue, "Work")
        XCTAssertNil(dict["body"])
    }

    func test_recent_returnsModificationDate() async throws {
        // Given
        let stdout = """
        {"success": true, "data": [{"note_id": "note-1", "title": "Alpha", "folder": "Work", "modification_date": "2026-02-01"}]}
        """
        let runner = NotesRecentMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesRecentTool(runner: runner)

        // When
        let result = try await tool.execute(args: [:])

        // Then
        guard case .array(let items) = result.json,
              case .object(let dict) = items.first else {
            return XCTFail("Expected array with object")
        }
        XCTAssertEqual(dict["modification_date"]?.stringValue, "2026-02-01")
    }

    func test_recent_respectsLimit() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = NotesRecentMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [
            "limit": .number(3)
        ])

        // Then
        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set limitCount to 3") ?? false)
    }

    func test_recent_defaultsLimit() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = NotesRecentMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [:])

        // Then
        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set limitCount to 10") ?? false)
    }

    func test_recent_clampsLimit() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = NotesRecentMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [
            "limit": .number(100)
        ])

        // Then
        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set limitCount to 50") ?? false)
    }

    func test_recent_passesFolderFilter() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = NotesRecentMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [
            "folder": .string("Work")
        ])

        // Then
        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set folderName to \"Work\"") ?? false)
    }

    func test_recent_passesAccountFilter() async throws {
        // Given
        let stdout = """
        {"success": true, "data": []}
        """
        let runner = NotesRecentMockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesRecentTool(runner: runner)

        // When
        _ = try await tool.execute(args: [
            "account": .string("iCloud")
        ])

        // Then
        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set accountName to \"iCloud\"") ?? false)
    }

    func test_recent_noRequiredParams() {
        // Given
        let tool = NotesRecentTool()

        // When / Then
        XCTAssertNoThrow(try tool.validate(args: [:]))
    }

    // MARK: - Helpers

    private static func makeResult(stdout: String) -> AppleScriptResult {
        AppleScriptResult(stdout: stdout, json: nil, duration: 0)
    }
}

// MARK: - Mock AppleScriptRunner

actor NotesRecentMockAppleScriptRunner: AppleScriptRunning {
    private(set) var lastScript: String?
    private(set) var lastConfig: AppleScriptConfig?

    private let result: Result<AppleScriptResult, Error>

    init(result: Result<AppleScriptResult, Error>) {
        self.result = result
    }

    func execute(script: String, config: AppleScriptConfig) async throws -> AppleScriptResult {
        self.lastScript = script
        self.lastConfig = config
        return try self.result.get()
    }
}
