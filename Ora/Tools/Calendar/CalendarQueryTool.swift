//
//  CalendarQueryTool.swift
//  Ora
//
//  Query calendar events in a date range
//

import Foundation
@preconcurrency import EventKit

struct CalendarQueryTool: Tool {
    let name = "calendar.query"
    let kind: ToolKind = .read

    var loadPolicy: ToolLoadPolicy {
        .core
    }
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Query calendar events within a date range",
            parameters: [
                "start": ParameterSchema(type: "string", description: "Start date/time (ISO 8601)", format: "date-time"),
                "end": ParameterSchema(type: "string", description: "End date/time (ISO 8601)", format: "date-time"),
                "calendar_id": ParameterSchema(type: "string", description: "Optional calendar ID to filter by")
            ],
            requiredParameters: ["start", "end"],
            requiresConfirmation: false
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let startStr = args["start"]?.stringValue else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: start")
        }
        guard let endStr = args["end"]?.stringValue else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: end")
        }
        guard EventStoreProvider.parseDate(startStr) != nil else {
            throw CalendarToolError.invalidDateFormat(startStr)
        }
        guard EventStoreProvider.parseDate(endStr) != nil else {
            throw CalendarToolError.invalidDateFormat(endStr)
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        // Check calendar permission first
        try await EventStoreProvider.ensureCalendarAccess()
        
        let store = EventStoreProvider.shared
        
        guard let startStr = args["start"]?.stringValue,
              let endStr = args["end"]?.stringValue,
              let start = EventStoreProvider.parseDate(startStr),
              let end = EventStoreProvider.parseDate(endStr) else {
            throw CalendarToolError.invalidDateFormat("start or end")
        }
        
        // Optional calendar filter
        var calendars: [EKCalendar]? = nil
        if let calendarID = args["calendar_id"]?.stringValue,
           let calendar = store.calendar(withIdentifier: calendarID) {
            calendars = [calendar]
        }
        
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate)
        
        let eventData: [JSONValue] = events.compactMap { event in
            guard let eventStart = event.startDate, let eventEnd = event.endDate else {
                return nil
            }
            return .object([
                "id": .string(event.eventIdentifier),
                "title": .string(event.title ?? ""),
                "start": .string(EventStoreProvider.formatDate(eventStart)),
                "end": .string(EventStoreProvider.formatDate(eventEnd)),
                "location": .string(event.location ?? ""),
                "calendar": .string(event.calendar.title),
                "is_all_day": .bool(event.isAllDay)
            ])
        }
        
        let summary: String
        if events.isEmpty {
            summary = "No events found in that time range."
        } else if events.count == 1 {
            summary = "Found 1 event: \(events[0].title ?? "Untitled")."
        } else {
            summary = "Found \(events.count) events."
        }
        
        return .success(.array(eventData), summary: summary)
    }
}
