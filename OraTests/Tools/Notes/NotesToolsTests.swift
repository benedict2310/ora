//
//  NotesToolsTests.swift
//  OraTests
//
//  Tests for Notes tools
//

import XCTest
@testable import Ora

final class NotesToolsTests: XCTestCase {

    func test_createTool_schema() {
        let tool = NotesCreateTool()
        XCTAssertEqual(tool.name, "notes.create_note")
        XCTAssertEqual(tool.kind, .mutate)
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["body"])
        XCTAssertNotNil(tool.schema.parameters["body"])
        XCTAssertNotNil(tool.schema.parameters["title"])
        XCTAssertNotNil(tool.schema.parameters["folder"])
        XCTAssertNotNil(tool.schema.parameters["account"])
    }

    func test_searchTool_schema() {
        let tool = NotesSearchTool()
        XCTAssertEqual(tool.name, "notes.search_notes")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["query"])
        XCTAssertNotNil(tool.schema.parameters["query"])
        XCTAssertNotNil(tool.schema.parameters["limit"])
    }

    func test_recentTool_schema() {
        let tool = NotesRecentTool()
        XCTAssertEqual(tool.name, "notes.recent")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertTrue(tool.schema.requiredParameters.isEmpty)
        XCTAssertNotNil(tool.schema.parameters["folder"])
        XCTAssertNotNil(tool.schema.parameters["account"])
        XCTAssertNotNil(tool.schema.parameters["limit"])
    }

    func test_openTool_schema() {
        let tool = NotesOpenTool()
        XCTAssertEqual(tool.name, "notes.open_note")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["note_id"])
        XCTAssertNotNil(tool.schema.parameters["note_id"])
    }

    func test_readTool_schema() {
        let tool = NotesReadTool()
        XCTAssertEqual(tool.name, "notes.read_note")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["note_id"])
        XCTAssertNotNil(tool.schema.parameters["note_id"])
        XCTAssertNotNil(tool.schema.parameters["max_chars"])
    }

    func test_editTool_schema() {
        let tool = NotesEditTool()
        XCTAssertEqual(tool.name, "notes.edit_note")
        XCTAssertEqual(tool.kind, .mutate)
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["note_id", "text"])
        XCTAssertNotNil(tool.schema.parameters["note_id"])
        XCTAssertNotNil(tool.schema.parameters["text"])
        XCTAssertNotNil(tool.schema.parameters["mode"])
    }

    func test_listFoldersTool_schema() {
        let tool = NotesListFoldersTool()
        XCTAssertEqual(tool.name, "notes.list_folders")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertTrue(tool.schema.requiredParameters.isEmpty)
        XCTAssertNotNil(tool.schema.parameters["account"])
    }

    func test_notesToolsRegistered() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        let create = await ToolRegistry.shared.tool(named: "notes.create_note")
        let search = await ToolRegistry.shared.tool(named: "notes.search_notes")
        let recent = await ToolRegistry.shared.tool(named: "notes.recent")
        let open = await ToolRegistry.shared.tool(named: "notes.open_note")
        let read = await ToolRegistry.shared.tool(named: "notes.read_note")
        let edit = await ToolRegistry.shared.tool(named: "notes.edit_note")
        let list = await ToolRegistry.shared.tool(named: "notes.list_folders")

        XCTAssertNotNil(create)
        XCTAssertNotNil(search)
        XCTAssertNotNil(recent)
        XCTAssertNotNil(open)
        XCTAssertNotNil(read)
        XCTAssertNotNil(edit)
        XCTAssertNotNil(list)
    }

    func test_createTool_validate_requiresBody() {
        let tool = NotesCreateTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_searchTool_validate_requiresQuery() {
        let tool = NotesSearchTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_searchTool_validate_rejectsBroadQuery() {
        let tool = NotesSearchTool()
        XCTAssertThrowsError(try tool.validate(args: ["query": .string("all")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: ["query": .string("all notes")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: ["query": .string("ok")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_openTool_validate_requiresNoteId() {
        let tool = NotesOpenTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_readTool_validate_requiresNoteId() {
        let tool = NotesReadTool()
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_editTool_validate_requiresNoteIdAndText() {
        let tool = NotesEditTool()
        XCTAssertThrowsError(try tool.validate(args: ["text": .string("Hi")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
        XCTAssertThrowsError(try tool.validate(args: ["note_id": .string("n1")])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_editTool_validate_rejectsInvalidMode() {
        let tool = NotesEditTool()
        XCTAssertThrowsError(
            try tool.validate(args: ["note_id": .string("n1"), "text": .string("Hi"), "mode": .string("merge")])
        ) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_createNote_execute_parsesEnvelope() async throws {
        let stdout = """
        {"success": true, "data": {"note_id": "note-123", "title": "Greeting", "folder": "Work", "account": "iCloud"}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesCreateTool(runner: runner)

        let result = try await tool.execute(args: [
            "body": .string("Hello world"),
            "title": .string("Greeting"),
            "folder": .string("Work"),
            "account": .string("iCloud")
        ])

        XCTAssertEqual(result.humanSummary, "Created note 'Greeting' in Work.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["note_id"]?.stringValue, "note-123")
            XCTAssertEqual(dict["title"]?.stringValue, "Greeting")
            XCTAssertEqual(dict["folder"]?.stringValue, "Work")
            XCTAssertEqual(dict["account"]?.stringValue, "iCloud")
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set accountName to \"iCloud\"") ?? false)
        XCTAssertTrue(script?.contains("set folderName to \"Work\"") ?? false)
        XCTAssertTrue(script?.contains("make new note") ?? false)

        let config = await runner.lastConfig
        XCTAssertTrue(config?.expectsJSON ?? false)
    }

    func test_searchNotes_execute_returnsSummary() async throws {
        let stdout = """
        {"success": true, "data": {"items": [{"note_id": "n1", "title": "Alpha", "folder": "Notes"}], "total_count": 1}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Alpha"),
            "limit": .number(5)
        ])

        XCTAssertEqual(result.humanSummary, "Found 1 note matching 'Alpha'.")

        if case .object(let dict) = result.json,
           case .array(let items) = dict["items"],
           case .object(let first)? = items.first {
            XCTAssertEqual(first["note_id"]?.stringValue, "n1")
            XCTAssertEqual(dict["total_count"]?.numberValue, 1)
            XCTAssertEqual(dict["returned_count"]?.numberValue, 1)
            XCTAssertEqual(dict["remaining_count"]?.numberValue, 0)
            XCTAssertEqual(dict["truncated"]?.boolValue, false)
            XCTAssertNil(dict["recommendation"])
        } else {
            XCTFail("Expected items array")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set queryText to \"Alpha\"") ?? false)
        XCTAssertTrue(script?.contains("set limitCount to 5") ?? false)
    }

    func test_searchNotes_execute_stripsWrappingQuotes() async throws {
        let stdout = """
        {"success": true, "data": {"items": [], "total_count": 0}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesSearchTool(runner: runner)

        _ = try await tool.execute(args: [
            "query": .string("\"middle management\""),
            "limit": .number(5)
        ])

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set queryText to \"middle management\"") ?? false)
    }

    func test_searchNotes_execute_stripsTrailingPunctuation() async throws {
        let stdout = """
        {"success": true, "data": {"items": [], "total_count": 0}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesSearchTool(runner: runner)

        _ = try await tool.execute(args: [
            "query": .string("middle management?"),
            "limit": .number(5)
        ])

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set queryText to \"middle management\"") ?? false)
    }

    func test_searchNotes_execute_reportsTruncation() async throws {
        let stdout = """
        {"success": true, "data": {"items": [{"note_id": "n1", "title": "Alpha", "folder": "Notes"}, {"note_id": "n2", "title": "Beta", "folder": "Notes"}], "total_count": 5}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesSearchTool(runner: runner)

        let result = try await tool.execute(args: [
            "query": .string("Alpha"),
            "limit": .number(2)
        ])

        XCTAssertTrue(result.humanSummary.contains("5 notes"))
        XCTAssertTrue(result.humanSummary.contains("3 more not shown"))
        XCTAssertTrue(result.humanSummary.contains("more specific query"))

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["total_count"]?.numberValue, 5)
            XCTAssertEqual(dict["returned_count"]?.numberValue, 2)
            XCTAssertEqual(dict["remaining_count"]?.numberValue, 3)
            XCTAssertEqual(dict["truncated"]?.boolValue, true)
            XCTAssertEqual(
                dict["recommendation"]?.stringValue,
                "Try a more specific query to see more results."
            )
        } else {
            XCTFail("Expected object result")
        }
    }

    func test_openNote_execute_returnsSummary() async throws {
        let stdout = """
        {"success": true, "data": {"note_id": "note-xyz", "title": "Meeting Notes"}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesOpenTool(runner: runner)

        let result = try await tool.execute(args: [
            "note_id": .string("note-xyz")
        ])

        XCTAssertEqual(result.humanSummary, "Opened note 'Meeting Notes'.")

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set noteId to \"note-xyz\"") ?? false)
    }

    func test_openNote_execute_normalizesNoteId() async throws {
        let stdout = """
        {"success": true, "data": {"note_id": "note-xyz", "title": "Meeting Notes"}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesOpenTool(runner: runner)

        _ = try await tool.execute(args: [
            "note_id": .string("x-coredata:///ABC/ICNote/p1")
        ])

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set noteId to \"x-coredata://ABC/ICNote/p1\"") ?? false)
    }

    func test_readNote_execute_returnsSummary() async throws {
        let stdout = """
        {"success": true, "data": {"note_id": "n1", "title": "Alpha", "body": "Hello", "total_chars": 5, "returned_chars": 5, "remaining_chars": 0, "truncated": false}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesReadTool(runner: runner)

        let result = try await tool.execute(args: [
            "note_id": .string("n1"),
            "max_chars": .number(1200)
        ])

        XCTAssertEqual(result.humanSummary, "Read note 'Alpha'.")

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["body"]?.stringValue, "Hello")
            XCTAssertEqual(dict["truncated"]?.boolValue, false)
            XCTAssertNil(dict["recommendation"])
        } else {
            XCTFail("Expected object result")
        }

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set noteId to \"n1\"") ?? false)
    }

    func test_readNote_execute_normalizesNoteId() async throws {
        let stdout = """
        {"success": true, "data": {"note_id": "n1", "title": "Alpha", "body": "Hello", "total_chars": 5, "returned_chars": 5, "remaining_chars": 0, "truncated": false}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesReadTool(runner: runner)

        _ = try await tool.execute(args: [
            "note_id": .string("x-coredata:///ABC/ICNote/p1")
        ])

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set noteId to \"x-coredata://ABC/ICNote/p1\"") ?? false)
    }

    func test_readNote_execute_reportsTruncation() async throws {
        let stdout = """
        {"success": true, "data": {"note_id": "n1", "title": "Alpha", "body": "Hello", "total_chars": 20, "returned_chars": 5, "remaining_chars": 15, "truncated": true}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesReadTool(runner: runner)

        let result = try await tool.execute(args: [
            "note_id": .string("n1")
        ])

        XCTAssertTrue(result.humanSummary.contains("Showing 5 of 20"))

        if case .object(let dict) = result.json {
            XCTAssertEqual(dict["remaining_chars"]?.numberValue, 15)
            XCTAssertEqual(dict["truncated"]?.boolValue, true)
            XCTAssertEqual(dict["recommendation"]?.stringValue, "Ask to read more or lower max_chars.")
        } else {
            XCTFail("Expected object result")
        }
    }

    func test_editNote_execute_returnsSummary() async throws {
        let stdout = """
        {"success": true, "data": {"note_id": "n1", "title": "Alpha", "mode": "append"}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesEditTool(runner: runner)

        let result = try await tool.execute(args: [
            "note_id": .string("n1"),
            "text": .string("Extra"),
            "mode": .string("append")
        ])

        XCTAssertEqual(result.humanSummary, "Appended to note 'Alpha'.")

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set noteId to \"n1\"") ?? false)
        XCTAssertTrue(script?.contains("set editMode to \"append\"") ?? false)
    }

    func test_editNote_execute_normalizesNoteId() async throws {
        let stdout = """
        {"success": true, "data": {"note_id": "n1", "title": "Alpha", "mode": "append"}}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesEditTool(runner: runner)

        _ = try await tool.execute(args: [
            "note_id": .string("x-coredata:///ABC/ICNote/p1"),
            "text": .string("Extra"),
            "mode": .string("append")
        ])

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set noteId to \"x-coredata://ABC/ICNote/p1\"") ?? false)
    }

    func test_listFolders_execute_usesAccountFilter() async throws {
        let stdout = """
        {"success": true, "data": [{"name": "Inbox", "account": "iCloud"}]}
        """
        let runner = MockAppleScriptRunner(result: .success(Self.makeResult(stdout: stdout)))
        let tool = NotesListFoldersTool(runner: runner)

        let result = try await tool.execute(args: [
            "account": .string("iCloud")
        ])

        XCTAssertEqual(result.humanSummary, "Found 1 folder in iCloud.")

        let script = await runner.lastScript
        XCTAssertTrue(script?.contains("set accountName to \"iCloud\"") ?? false)
    }

    func test_parseEnvelope_mapsFolderNotFound() {
        let stdout = """
        {"success": false, "error": "Folder not found: Work", "code": 1002}
        """
        let result = Self.makeResult(stdout: stdout)

        XCTAssertThrowsError(try NotesAppleScript.parseEnvelope(result)) { error in
            XCTAssertEqual(error as? NotesToolError, .folderNotFound("Work"))
        }
    }

    func test_parseEnvelope_mapsPermissionDenied() {
        let stdout = """
        {"success": false, "error": "Not authorized to send Apple events to Notes.", "code": -1743}
        """
        let result = Self.makeResult(stdout: stdout)

        XCTAssertThrowsError(try NotesAppleScript.parseEnvelope(result)) { error in
            XCTAssertEqual(error as? NotesToolError, .permissionDenied)
        }
    }

    func test_parseEnvelope_unescapesEscapedJSON() throws {
        let stdout = """
        {\\\"success\\\": true, \\\"data\\\": {\\\"items\\\": [], \\\"total_count\\\": 0}}
        """
        let result = Self.makeResult(stdout: stdout)

        let data = try NotesAppleScript.parseEnvelope(result)

        if case .object(let dict) = data,
           case .array(let items) = dict["items"] {
            XCTAssertEqual(items.count, 0)
            XCTAssertEqual(dict["total_count"]?.numberValue, 0)
        } else {
            XCTFail("Expected data object with items array")
        }
    }

    func test_permissionDeniedError_hasRemediation() {
        let description = NotesToolError.permissionDenied.localizedDescription
        XCTAssertTrue(description.contains("System Settings"))
        XCTAssertTrue(description.contains("Automation"))
    }

    private static func makeResult(stdout: String) -> AppleScriptResult {
        AppleScriptResult(stdout: stdout, json: nil, duration: 0)
    }
}

// MARK: - Mock AppleScriptRunner

actor MockAppleScriptRunner: AppleScriptRunning {
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
