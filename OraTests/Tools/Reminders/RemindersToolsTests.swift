//
//  RemindersToolsTests.swift
//  OraTests
//
//  Tests for Reminders Tools
//

import EventKit
import XCTest
@testable import Ora

final class RemindersToolsTests: XCTestCase {

    // MARK: - RemindersStoreProvider Tests

    func test_findReminderList_exactMatch_preferred() {
        let store = EKEventStore()
        let calendars = [
            makeCalendar(title: "Shopping List", store: store),
            makeCalendar(title: "Shopping", store: store),
            makeCalendar(title: "Work", store: store)
        ]
        let match = RemindersStoreProvider.findReminderList(
            named: "shopping",
            in: calendars,
            allowFuzzy: true
        )
        XCTAssertEqual(match?.title, "Shopping")
    }

    func test_findReminderList_fuzzyFallback_findsCloseMatch() {
        let store = EKEventStore()
        let calendars = [
            makeCalendar(title: "Grocery List", store: store),
            makeCalendar(title: "Work", store: store)
        ]
        let match = RemindersStoreProvider.findReminderList(
            named: "groceries",
            in: calendars,
            allowFuzzy: true
        )
        XCTAssertEqual(match?.title, "Grocery List")
    }

    func test_findReminderList_fuzzyFallback_respectsThreshold() {
        let store = EKEventStore()
        let calendars = [
            makeCalendar(title: "Shopping", store: store),
            makeCalendar(title: "Work", store: store)
        ]
        let match = RemindersStoreProvider.findReminderList(
            named: "xyzgarbage",
            in: calendars,
            allowFuzzy: true
        )
        XCTAssertNil(match)
    }

    func test_findReminderList_fuzzyFallback_returnsBestMatch() {
        let store = EKEventStore()
        let calendars = [
            makeCalendar(title: "Grocery", store: store),
            makeCalendar(title: "Grocery List", store: store),
            makeCalendar(title: "Groceries", store: store)
        ]
        let query = "groceri list"
        let match = RemindersStoreProvider.findReminderList(
            named: query,
            in: calendars,
            allowFuzzy: true
        )
        let best = calendars
            .map { calendar in
                (calendar: calendar, score: StringSimilarity.jaroWinkler(query, calendar.title))
            }
            .sorted { $0.score > $1.score }
            .first
        XCTAssertEqual(match?.title, best?.calendar.title)
    }

    private func makeCalendar(title: String, store: EKEventStore) -> EKCalendar {
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title
        return calendar
    }

    // MARK: - List Tool Tests

    func test_listTool_validate_success() throws {
        let tool = RemindersListTool()

        // No required parameters
        XCTAssertNoThrow(try tool.validate(args: [:]))
    }

    func test_listTool_validate_withOptionalParams() throws {
        let tool = RemindersListTool()

        XCTAssertNoThrow(try tool.validate(args: [
            "list_name": .string("Shopping"),
            "include_completed": .bool(true)
        ]))
    }

    func test_listTool_schema() {
        let tool = RemindersListTool()
        XCTAssertEqual(tool.name, "reminders.list")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, [])
    }

    func test_listTool_summary_noReminders() {
        let summary = RemindersListTool.summary(for: 0, listName: nil, includeCompleted: false)
        XCTAssertEqual(summary, "No reminders found.")
    }

    func test_listTool_summary_withListName() {
        let summary = RemindersListTool.summary(for: 0, listName: "Work", includeCompleted: false)
        XCTAssertEqual(summary, "No reminders found in 'Work'.")
    }

    func test_listTool_summary_includeCompleted() {
        let summary = RemindersListTool.summary(for: 0, listName: nil, includeCompleted: true)
        XCTAssertEqual(summary, "No reminders found (including completed).")
    }

    func test_listTool_summary_oneReminder() {
        let summary = RemindersListTool.summary(for: 1, listName: nil, includeCompleted: false)
        XCTAssertEqual(summary, "Found 1 reminder.")
    }

    func test_listTool_summary_multipleReminders() {
        let summary = RemindersListTool.summary(for: 5, listName: "Shopping", includeCompleted: true)
        XCTAssertEqual(summary, "Found 5 reminders in 'Shopping' (including completed).")
    }

    func test_listTool_snapshotToJSON() {
        let snapshot = ReminderSnapshot(
            id: "test-id",
            title: "Buy milk",
            dueDate: nil,
            isCompleted: false,
            listName: "Shopping",
            priority: 1,
            notes: "2% milk"
        )

        let json = RemindersListTool.snapshotToJSON(snapshot)

        guard case .object(let obj) = json else {
            XCTFail("Expected object")
            return
        }

        XCTAssertEqual(obj["id"]?.stringValue, "test-id")
        XCTAssertEqual(obj["title"]?.stringValue, "Buy milk")
        XCTAssertEqual(obj["completed"]?.boolValue, false)
        XCTAssertEqual(obj["list"]?.stringValue, "Shopping")
        XCTAssertEqual(obj["priority"]?.numberValue, 1)
        XCTAssertEqual(obj["notes"]?.stringValue, "2% milk")
    }

    // MARK: - Create Tool Tests

    func test_createTool_validate_success() throws {
        let tool = RemindersCreateTool()

        XCTAssertNoThrow(try tool.validate(args: [
            "title": .string("Buy groceries")
        ]))
    }

    func test_createTool_validate_withOptionalParams() throws {
        let tool = RemindersCreateTool()

        XCTAssertNoThrow(try tool.validate(args: [
            "title": .string("Buy groceries"),
            "due_date": .string("2026-01-15T10:00:00Z"),
            "list_name": .string("Shopping"),
            "notes": .string("Milk, eggs, bread"),
            "priority": .number(1)
        ]))
    }

    func test_createTool_validate_missingTitle() {
        let tool = RemindersCreateTool()

        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_createTool_validate_emptyTitle() {
        let tool = RemindersCreateTool()

        XCTAssertThrowsError(try tool.validate(args: [
            "title": .string("")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_createTool_validate_invalidDateFormat() {
        let tool = RemindersCreateTool()

        XCTAssertThrowsError(try tool.validate(args: [
            "title": .string("Test"),
            "due_date": .string("not-a-date")
        ])) { error in
            XCTAssertTrue(error is RemindersToolError)
        }
    }

    func test_createTool_validate_invalidPriority_tooHigh() {
        let tool = RemindersCreateTool()

        XCTAssertThrowsError(try tool.validate(args: [
            "title": .string("Test"),
            "priority": .number(10)
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_createTool_validate_invalidPriority_negative() {
        let tool = RemindersCreateTool()

        XCTAssertThrowsError(try tool.validate(args: [
            "title": .string("Test"),
            "priority": .number(-1)
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_createTool_validate_validPriorityBounds() throws {
        let tool = RemindersCreateTool()

        XCTAssertNoThrow(try tool.validate(args: [
            "title": .string("Test"),
            "priority": .number(0)
        ]))

        XCTAssertNoThrow(try tool.validate(args: [
            "title": .string("Test"),
            "priority": .number(9)
        ]))
    }

    func test_createTool_requiresConfirmation() {
        let tool = RemindersCreateTool()
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.kind, .mutate)
    }

    func test_createTool_schema() {
        let tool = RemindersCreateTool()
        XCTAssertEqual(tool.name, "reminders.create")
        XCTAssertTrue(tool.schema.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["title"])
    }

    func test_createTool_summary_withDueDate() {
        let summary = RemindersCreateTool.summary(
            title: "Buy groceries",
            dueDate: "2026-01-15T10:00:00Z",
            list: "Shopping"
        )
        XCTAssertTrue(summary.contains("Buy groceries"))
        XCTAssertTrue(summary.contains("Shopping"))
        XCTAssertTrue(summary.contains("due"))
    }

    func test_createTool_summary_withoutDueDate() {
        let summary = RemindersCreateTool.summary(
            title: "Buy groceries",
            dueDate: nil,
            list: "Shopping"
        )
        XCTAssertEqual(summary, "Created reminder 'Buy groceries' in 'Shopping'.")
    }

    // MARK: - Complete Tool Tests

    func test_completeTool_validate_success() throws {
        let tool = RemindersCompleteTool()

        XCTAssertNoThrow(try tool.validate(args: [
            "reminder_id": .string("12345")
        ]))
    }

    func test_completeTool_validate_missingID() {
        let tool = RemindersCompleteTool()

        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_completeTool_validate_emptyID() {
        let tool = RemindersCompleteTool()

        XCTAssertThrowsError(try tool.validate(args: [
            "reminder_id": .string("")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_completeTool_requiresConfirmation() {
        let tool = RemindersCompleteTool()
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.kind, .mutate)
    }

    func test_completeTool_schema() {
        let tool = RemindersCompleteTool()
        XCTAssertEqual(tool.name, "reminders.complete")
        XCTAssertTrue(tool.schema.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["reminder_id"])
    }

    // MARK: - Edit Tool Tests

    func test_editTool_validate_success() throws {
        let tool = RemindersEditTool()

        XCTAssertNoThrow(try tool.validate(args: [
            "reminder_id": .string("12345")
        ]))
    }

    func test_editTool_validate_withOptionalFields() throws {
        let tool = RemindersEditTool()

        XCTAssertNoThrow(try tool.validate(args: [
            "reminder_id": .string("12345"),
            "title": .string("New Title"),
            "due_date": .string("2026-01-15T10:00:00Z"),
            "notes": .string("Updated notes"),
            "priority": .number(5),
            "list_name": .string("Work")
        ]))
    }

    func test_editTool_validate_missingID() {
        let tool = RemindersEditTool()

        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_editTool_validate_emptyID() {
        let tool = RemindersEditTool()

        XCTAssertThrowsError(try tool.validate(args: [
            "reminder_id": .string("")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_editTool_validate_invalidDateFormat() {
        let tool = RemindersEditTool()

        XCTAssertThrowsError(try tool.validate(args: [
            "reminder_id": .string("12345"),
            "due_date": .string("invalid-date")
        ])) { error in
            XCTAssertTrue(error is RemindersToolError)
        }
    }

    func test_editTool_validate_invalidPriority() {
        let tool = RemindersEditTool()

        XCTAssertThrowsError(try tool.validate(args: [
            "reminder_id": .string("12345"),
            "priority": .number(10)
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }

    func test_editTool_requiresConfirmation() {
        let tool = RemindersEditTool()
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.kind, .mutate)
    }

    func test_editTool_schema() {
        let tool = RemindersEditTool()
        XCTAssertEqual(tool.name, "reminders.edit")
        XCTAssertTrue(tool.schema.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["reminder_id"])
    }

    // MARK: - RemindersToolError Tests

    func test_remindersToolError_descriptions() {
        XCTAssertNotNil(RemindersToolError.reminderNotFound("123").errorDescription)
        XCTAssertNotNil(RemindersToolError.invalidDateFormat("test").errorDescription)
        XCTAssertNotNil(RemindersToolError.noDefaultList.errorDescription)
        XCTAssertNotNil(RemindersToolError.permissionDenied.errorDescription)
        XCTAssertNotNil(RemindersToolError.saveFailed("reason").errorDescription)
        XCTAssertNotNil(RemindersToolError.deleteFailed("reason").errorDescription)
    }

    func test_remindersToolError_reminderNotFound_containsID() {
        let error = RemindersToolError.reminderNotFound("reminder-123")
        XCTAssertTrue(error.errorDescription?.contains("reminder-123") ?? false)
    }

    func test_remindersToolError_invalidDateFormat_containsValue() {
        let error = RemindersToolError.invalidDateFormat("bad-date")
        XCTAssertTrue(error.errorDescription?.contains("bad-date") ?? false)
    }

    // MARK: - RemindersStoreProvider Tests

    func test_remindersStoreProvider_authorizationAction_mapping() {
        XCTAssertEqual(RemindersStoreProvider.authorizationAction(for: .authorized), .authorized)
        XCTAssertEqual(RemindersStoreProvider.authorizationAction(for: .fullAccess), .authorized)
        XCTAssertEqual(RemindersStoreProvider.authorizationAction(for: .notDetermined), .requestAccess)
        XCTAssertEqual(RemindersStoreProvider.authorizationAction(for: .denied), .denied)
        XCTAssertEqual(RemindersStoreProvider.authorizationAction(for: .writeOnly), .denied)
        XCTAssertEqual(RemindersStoreProvider.authorizationAction(for: .restricted), .denied)
    }

    // MARK: - Tool Registration Tests

    func test_remindersToolsRegistered() async {
        // Clear and register
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        // Verify all reminders tools are registered
        let list = await ToolRegistry.shared.tool(named: "reminders.list")
        let create = await ToolRegistry.shared.tool(named: "reminders.create")
        let complete = await ToolRegistry.shared.tool(named: "reminders.complete")
        let edit = await ToolRegistry.shared.tool(named: "reminders.edit")

        XCTAssertNotNil(list)
        XCTAssertNotNil(create)
        XCTAssertNotNil(complete)
        XCTAssertNotNil(edit)

        // Verify total count (5 calendar + 4 reminders + 1 contacts + 7 skills + 7 notes + 2 messages + 7 mail + 11 system + 1 tools = 45)
        let allTools = await ToolRegistry.shared.allTools()
        XCTAssertEqual(allTools.count, 45)
    }

    func test_remindersToolSchemas() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        let schemas = await ToolRegistry.shared.schemas()
        let names = Set(schemas.map { $0.name })

        XCTAssertTrue(names.contains("reminders.list"))
        XCTAssertTrue(names.contains("reminders.create"))
        XCTAssertTrue(names.contains("reminders.complete"))
        XCTAssertTrue(names.contains("reminders.edit"))
    }
}
