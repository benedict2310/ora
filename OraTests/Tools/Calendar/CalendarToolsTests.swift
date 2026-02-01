//
//  CalendarToolsTests.swift
//  OraTests
//
//  Tests for Calendar Tools
//

import XCTest
@testable import Ora

final class CalendarToolsTests: XCTestCase {
    
    // MARK: - Query Tool Tests
    
    func test_queryTool_validate_success() throws {
        let tool = CalendarQueryTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "start": .string("2026-01-01T00:00:00Z"),
            "end": .string("2026-01-02T00:00:00Z")
        ]))
    }
    
    func test_queryTool_validate_missingStart() {
        let tool = CalendarQueryTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "end": .string("2026-01-02T00:00:00Z")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_queryTool_validate_missingEnd() {
        let tool = CalendarQueryTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "start": .string("2026-01-01T00:00:00Z")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_queryTool_validate_invalidDateFormat() {
        let tool = CalendarQueryTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "start": .string("not-a-date"),
            "end": .string("2026-01-02T00:00:00Z")
        ])) { error in
            XCTAssertTrue(error is CalendarToolError)
        }
    }
    
    func test_queryTool_schema() {
        let tool = CalendarQueryTool()
        XCTAssertEqual(tool.name, "calendar.query")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["start", "end"])
    }
    
    // MARK: - Create Event Tool Tests
    
    func test_createTool_validate_success() throws {
        let tool = CalendarCreateEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "title": .string("Meeting"),
            "start": .string("2026-01-15T10:00:00Z"),
            "end": .string("2026-01-15T11:00:00Z")
        ]))
    }
    
    func test_createTool_validate_missingTitle() {
        let tool = CalendarCreateEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "start": .string("2026-01-15T10:00:00Z"),
            "end": .string("2026-01-15T11:00:00Z")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_createTool_validate_emptyTitle() {
        let tool = CalendarCreateEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "title": .string(""),
            "start": .string("2026-01-15T10:00:00Z"),
            "end": .string("2026-01-15T11:00:00Z")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_createTool_validate_endBeforeStart() {
        let tool = CalendarCreateEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "title": .string("Meeting"),
            "start": .string("2026-01-15T11:00:00Z"),
            "end": .string("2026-01-15T10:00:00Z")
        ])) { error in
            XCTAssertTrue(error is CalendarToolError)
            if let calError = error as? CalendarToolError {
                XCTAssertEqual(calError.errorDescription, CalendarToolError.endBeforeStart.errorDescription)
            }
        }
    }
    
    func test_createTool_validate_invalidStartDate() {
        let tool = CalendarCreateEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "title": .string("Meeting"),
            "start": .string("invalid"),
            "end": .string("2026-01-15T11:00:00Z")
        ])) { error in
            XCTAssertTrue(error is CalendarToolError)
        }
    }
    
    func test_createTool_requiresConfirmation() {
        let tool = CalendarCreateEventTool()
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.kind, .mutate)
    }
    
    func test_createTool_schema() {
        let tool = CalendarCreateEventTool()
        XCTAssertEqual(tool.name, "calendar.create_event")
        XCTAssertTrue(tool.schema.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["title", "start", "end"])
    }
    
    // MARK: - Edit Event Tool Tests
    
    func test_editTool_validate_success() throws {
        let tool = CalendarEditEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345")
        ]))
    }
    
    func test_editTool_validate_withOptionalFields() throws {
        let tool = CalendarEditEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345"),
            "title": .string("New Title"),
            "start": .string("2026-01-15T10:00:00Z"),
            "span": .string("this")
        ]))
    }
    
    func test_editTool_validate_missingEventID() {
        let tool = CalendarEditEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_editTool_validate_emptyEventID() {
        let tool = CalendarEditEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "event_id": .string("")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_editTool_validate_invalidSpan() {
        let tool = CalendarEditEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "event_id": .string("12345"),
            "span": .string("invalid")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_editTool_validate_validSpanThis() throws {
        let tool = CalendarEditEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345"),
            "span": .string("this")
        ]))
    }
    
    func test_editTool_validate_validSpanFuture() throws {
        let tool = CalendarEditEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345"),
            "span": .string("future")
        ]))
    }
    
    func test_editTool_validate_invalidStartDate() {
        let tool = CalendarEditEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "event_id": .string("12345"),
            "start": .string("invalid-date")
        ])) { error in
            XCTAssertTrue(error is CalendarToolError)
        }
    }
    
    func test_editTool_requiresConfirmation() {
        let tool = CalendarEditEventTool()
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.kind, .mutate)
    }
    
    func test_editTool_schema() {
        let tool = CalendarEditEventTool()
        XCTAssertEqual(tool.name, "calendar.edit_event")
        XCTAssertEqual(tool.schema.requiredParameters, ["event_id"])
    }
    
    // MARK: - Delete Event Tool Tests
    
    func test_deleteTool_validate_success() throws {
        let tool = CalendarDeleteEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345")
        ]))
    }
    
    func test_deleteTool_validate_missingEventID() {
        let tool = CalendarDeleteEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_deleteTool_validate_emptyEventID() {
        let tool = CalendarDeleteEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "event_id": .string("")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_deleteTool_validate_invalidSpan() {
        let tool = CalendarDeleteEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "event_id": .string("12345"),
            "span": .string("all")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_deleteTool_validate_validSpans() throws {
        let tool = CalendarDeleteEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345"),
            "span": .string("this")
        ]))
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345"),
            "span": .string("future")
        ]))
    }
    
    func test_deleteTool_requiresConfirmation() {
        let tool = CalendarDeleteEventTool()
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.kind, .mutate)
    }
    
    func test_deleteTool_schema() {
        let tool = CalendarDeleteEventTool()
        XCTAssertEqual(tool.name, "calendar.delete_event")
        XCTAssertEqual(tool.schema.requiredParameters, ["event_id"])
    }
    
    // MARK: - Find Slots Tool Tests
    
    func test_findSlotsTool_validate_success() throws {
        let tool = CalendarFindSlotsTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "start": .string("2026-01-15T08:00:00Z"),
            "end": .string("2026-01-15T18:00:00Z"),
            "duration_minutes": .number(30)
        ]))
    }
    
    func test_findSlotsTool_validate_missingStart() {
        let tool = CalendarFindSlotsTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "end": .string("2026-01-15T18:00:00Z"),
            "duration_minutes": .number(30)
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_findSlotsTool_validate_missingDuration() {
        let tool = CalendarFindSlotsTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "start": .string("2026-01-15T08:00:00Z"),
            "end": .string("2026-01-15T18:00:00Z")
        ])) { error in
            XCTAssertTrue(error is ToolHostError)
        }
    }
    
    func test_findSlotsTool_validate_invalidStartDate() {
        let tool = CalendarFindSlotsTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "start": .string("invalid-date"),
            "end": .string("2026-01-15T18:00:00Z"),
            "duration_minutes": .number(30)
        ])) { error in
            XCTAssertTrue(error is CalendarToolError)
        }
    }
    
    func test_findSlotsTool_validate_invalidEndDate() {
        let tool = CalendarFindSlotsTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "start": .string("2026-01-15T08:00:00Z"),
            "end": .string("not-a-date"),
            "duration_minutes": .number(30)
        ])) { error in
            XCTAssertTrue(error is CalendarToolError)
        }
    }
    
    func test_findSlotsTool_schema() {
        let tool = CalendarFindSlotsTool()
        XCTAssertEqual(tool.name, "calendar.find_slots")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
        XCTAssertEqual(tool.schema.requiredParameters, ["start", "end", "duration_minutes"])
    }

    func test_findSlotsTool_findSlots_respectsGapsAndMaxResults() {
        let rangeStart = self.makeDate(hour: 9, minute: 0)
        let rangeEnd = self.makeDate(hour: 12, minute: 0)
        let duration: TimeInterval = 20 * 60
        let busy = [
            (start: self.makeDate(hour: 9, minute: 30), end: self.makeDate(hour: 10, minute: 0)),
            (start: self.makeDate(hour: 10, minute: 30), end: self.makeDate(hour: 11, minute: 0))
        ]

        let slots = CalendarFindSlotsTool.findSlots(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            duration: duration,
            maxResults: 2,
            busyIntervals: busy
        )

        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots[0].start, rangeStart)
        XCTAssertEqual(slots[1].start, self.makeDate(hour: 10, minute: 0))
    }

    func test_findSlotsTool_findSlots_includesFinalGap() {
        let rangeStart = self.makeDate(hour: 9, minute: 0)
        let rangeEnd = self.makeDate(hour: 11, minute: 0)
        let duration: TimeInterval = 20 * 60
        let busy = [
            (start: self.makeDate(hour: 9, minute: 0), end: self.makeDate(hour: 10, minute: 30))
        ]

        let slots = CalendarFindSlotsTool.findSlots(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            duration: duration,
            maxResults: 5,
            busyIntervals: busy
        )

        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].start, self.makeDate(hour: 10, minute: 30))
    }

    func test_findSlotsTool_summary_messages() {
        let durationMinutes = 30.0
        XCTAssertEqual(CalendarFindSlotsTool.summary(for: [], durationMinutes: durationMinutes),
                       "No available slots found for 30 minutes.")

        let singleSlot = [(start: self.makeDate(hour: 9, minute: 0), end: self.makeDate(hour: 9, minute: 30))]
        let singleSummary = CalendarFindSlotsTool.summary(for: singleSlot, durationMinutes: durationMinutes)
        XCTAssertTrue(singleSummary.hasPrefix("Found 1 available slot at "))

        let twoSlots = [
            (start: self.makeDate(hour: 9, minute: 0), end: self.makeDate(hour: 9, minute: 30)),
            (start: self.makeDate(hour: 10, minute: 0), end: self.makeDate(hour: 10, minute: 30))
        ]
        XCTAssertEqual(CalendarFindSlotsTool.summary(for: twoSlots, durationMinutes: durationMinutes),
                       "Found 2 available slots.")
    }

    func test_findSlotsTool_slotData_formatsDates() {
        let slots = [(start: self.makeDate(hour: 9, minute: 0), end: self.makeDate(hour: 9, minute: 30))]
        let data = CalendarFindSlotsTool.slotData(for: slots)

        XCTAssertEqual(data.count, 1)
        guard case .object(let payload) = data[0] else {
            XCTFail("Expected object payload")
            return
        }
        XCTAssertNotNil(payload["start"]?.stringValue)
        XCTAssertNotNil(payload["end"]?.stringValue)
    }

    func test_createEventTool_summary_usesFormatter() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let date = self.makeDate(hour: 9, minute: 0)
        let expectedDate = formatter.string(from: date)
        let summary = CalendarCreateEventTool.summary(title: "Standup", start: date, formatter: formatter)
        XCTAssertEqual(summary, "Created 'Standup' on \(expectedDate).")
    }

    func test_createEventTool_summaryFormatter_styles() {
        let formatter = CalendarCreateEventTool.summaryFormatter()
        XCTAssertEqual(formatter.dateStyle, .medium)
        XCTAssertEqual(formatter.timeStyle, .short)
    }
    
    // MARK: - EventStoreProvider Tests
    
    func test_parseDate_iso8601() {
        let date = EventStoreProvider.parseDate("2026-01-15T10:30:00Z")
        XCTAssertNotNil(date)
    }
    
    func test_parseDate_withTimezone() {
        let date = EventStoreProvider.parseDate("2026-01-15T10:30:00-08:00")
        XCTAssertNotNil(date)
    }
    
    func test_parseDate_withFractionalSeconds() {
        let date = EventStoreProvider.parseDate("2026-01-15T10:30:00.123Z")
        XCTAssertNotNil(date)
    }
    
    func test_parseDate_invalid() {
        let date = EventStoreProvider.parseDate("not-a-date")
        XCTAssertNil(date)
    }
    
    func test_parseDate_emptyString() {
        let date = EventStoreProvider.parseDate("")
        XCTAssertNil(date)
    }

    func test_eventStoreProvider_authorizationAction_mapping() {
        XCTAssertEqual(EventStoreProvider.authorizationAction(for: .authorized), .authorized)
        XCTAssertEqual(EventStoreProvider.authorizationAction(for: .fullAccess), .authorized)
        XCTAssertEqual(EventStoreProvider.authorizationAction(for: .notDetermined), .requestAccess)
        XCTAssertEqual(EventStoreProvider.authorizationAction(for: .denied), .denied)
        XCTAssertEqual(EventStoreProvider.authorizationAction(for: .writeOnly), .denied)
        XCTAssertEqual(EventStoreProvider.authorizationAction(for: .restricted), .denied)
    }
    
    func test_formatDate_roundTrip() {
        let originalString = "2026-01-15T10:30:00.000Z"
        guard let date = EventStoreProvider.parseDate(originalString) else {
            XCTFail("Failed to parse date")
            return
        }
        
        let formatted = EventStoreProvider.formatDate(date)
        let reparsed = EventStoreProvider.parseDate(formatted)
        
        XCTAssertNotNil(reparsed)
        XCTAssertEqual(date.timeIntervalSince1970, reparsed!.timeIntervalSince1970, accuracy: 1.0)
    }
    
    // MARK: - CalendarToolError Tests
    
    func test_calendarToolError_descriptions() {
        XCTAssertNotNil(CalendarToolError.invalidDateFormat("test").errorDescription)
        XCTAssertNotNil(CalendarToolError.eventNotFound("123").errorDescription)
        XCTAssertNotNil(CalendarToolError.endBeforeStart.errorDescription)
        XCTAssertNotNil(CalendarToolError.noDefaultCalendar.errorDescription)
        XCTAssertNotNil(CalendarToolError.permissionDenied.errorDescription)
        XCTAssertNotNil(CalendarToolError.saveFailed("reason").errorDescription)
        XCTAssertNotNil(CalendarToolError.deleteFailed("reason").errorDescription)
    }
    
    func test_calendarToolError_invalidDateFormat_containsValue() {
        let error = CalendarToolError.invalidDateFormat("bad-date")
        XCTAssertTrue(error.errorDescription?.contains("bad-date") ?? false)
    }
    
    func test_calendarToolError_eventNotFound_containsID() {
        let error = CalendarToolError.eventNotFound("event-123")
        XCTAssertTrue(error.errorDescription?.contains("event-123") ?? false)
    }
    
    // MARK: - Tool Registration Tests
    
    func test_calendarToolsRegistered() async {
        // Clear and register
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()
        
        // Verify all calendar tools are registered
        let query = await ToolRegistry.shared.tool(named: "calendar.query")
        let findSlots = await ToolRegistry.shared.tool(named: "calendar.find_slots")
        let create = await ToolRegistry.shared.tool(named: "calendar.create_event")
        let edit = await ToolRegistry.shared.tool(named: "calendar.edit_event")
        let delete = await ToolRegistry.shared.tool(named: "calendar.delete_event")
        
        XCTAssertNotNil(query)
        XCTAssertNotNil(findSlots)
        XCTAssertNotNil(create)
        XCTAssertNotNil(edit)
        XCTAssertNotNil(delete)
        
        // Verify count (5 calendar + 4 reminders + 1 contacts + 7 notes + 2 messages + 7 mail + 11 system = 37)
        let allTools = await ToolRegistry.shared.allTools()
        XCTAssertEqual(allTools.count, 37)
    }

    func test_calendarToolSchemas() async {
        await ToolRegistry.shared.clear()
        await ToolRegistry.shared.registerDefaultTools()

        let schemas = await ToolRegistry.shared.schemas()
        XCTAssertEqual(schemas.count, 37)
        
        let names = Set(schemas.map { $0.name })
        XCTAssertTrue(names.contains("calendar.query"))
        XCTAssertTrue(names.contains("calendar.find_slots"))
        XCTAssertTrue(names.contains("calendar.create_event"))
        XCTAssertTrue(names.contains("calendar.edit_event"))
        XCTAssertTrue(names.contains("calendar.delete_event"))
    }

    private func makeDate(
        year: Int = 2026,
        month: Int = 1,
        day: Int = 15,
        hour: Int,
        minute: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
