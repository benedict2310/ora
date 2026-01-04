//
//  CalendarCreateEventTool.swift
//  Ora
//
//  Create new calendar events (requires confirmation)
//

import Foundation
import os
@preconcurrency import EventKit

struct CalendarCreateEventTool: Tool {
    let name = "calendar.create_event"
    let kind: ToolKind = .mutate
    
    private static let logger = Logger(subsystem: "com.ora.app", category: "CalendarCreateTool")
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create a new calendar event. Requires confirmation.",
            parameters: [
                "title": ParameterSchema(type: "string", description: "Event title"),
                "start": ParameterSchema(type: "string", description: "Start date/time (ISO 8601)", format: "date-time"),
                "end": ParameterSchema(type: "string", description: "End date/time (ISO 8601)", format: "date-time"),
                "location": ParameterSchema(type: "string", description: "Event location (optional)"),
                "notes": ParameterSchema(type: "string", description: "Event notes (optional)"),
                "calendar_id": ParameterSchema(type: "string", description: "Calendar ID (uses default if omitted)"),
                "is_all_day": ParameterSchema(type: "boolean", description: "All-day event (default false)")
            ],
            requiredParameters: ["title", "start", "end"],
            requiresConfirmation: true
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let title = args["title"]?.stringValue, !title.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: title")
        }
        guard let startStr = args["start"]?.stringValue,
              let start = EventStoreProvider.parseDate(startStr) else {
            throw CalendarToolError.invalidDateFormat(args["start"]?.stringValue ?? "nil")
        }
        guard let endStr = args["end"]?.stringValue,
              let end = EventStoreProvider.parseDate(endStr) else {
            throw CalendarToolError.invalidDateFormat(args["end"]?.stringValue ?? "nil")
        }
        guard end > start else {
            throw CalendarToolError.endBeforeStart
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        Self.logger.info("CalendarCreateEventTool.execute called with args: \(args.keys.joined(separator: ", "))")
        
        // Check calendar permission first
        try await EventStoreProvider.ensureCalendarAccess()
        Self.logger.info("Calendar access confirmed")
        
        let store = EventStoreProvider.shared
        
        guard let title = args["title"]?.stringValue,
              let startStr = args["start"]?.stringValue,
              let endStr = args["end"]?.stringValue,
              let start = EventStoreProvider.parseDate(startStr),
              let end = EventStoreProvider.parseDate(endStr) else {
            Self.logger.error("Failed to parse args: title=\(args["title"]?.stringValue ?? "nil"), start=\(args["start"]?.stringValue ?? "nil"), end=\(args["end"]?.stringValue ?? "nil")")
            throw CalendarToolError.invalidDateFormat("title, start, or end")
        }
        
        Self.logger.info("Creating event: \(title) from \(startStr) to \(endStr)")
        
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = args["location"]?.stringValue
        event.notes = args["notes"]?.stringValue
        event.isAllDay = args["is_all_day"]?.boolValue ?? false
        
        // Set calendar
        if let calendarID = args["calendar_id"]?.stringValue,
           let calendar = store.calendar(withIdentifier: calendarID) {
            event.calendar = calendar
            Self.logger.info("Using specified calendar: \(calendar.title)")
        } else {
            guard let defaultCalendar = store.defaultCalendarForNewEvents else {
                Self.logger.error("No default calendar available")
                throw CalendarToolError.noDefaultCalendar
            }
            event.calendar = defaultCalendar
            Self.logger.info("Using default calendar: \(defaultCalendar.title)")
        }
        
        do {
            try store.save(event, span: .thisEvent, commit: true)
            Self.logger.info("Event saved successfully with ID: \(event.eventIdentifier ?? "nil")")
        } catch {
            Self.logger.error("Failed to save event: \(error.localizedDescription)")
            throw CalendarToolError.saveFailed(error.localizedDescription)
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        let summary = "Created '\(title)' on \(formatter.string(from: start))."
        
        return .success(
            .object([
                "event_id": .string(event.eventIdentifier),
                "title": .string(title),
                "start": .string(EventStoreProvider.formatDate(start)),
                "end": .string(EventStoreProvider.formatDate(end))
            ]),
            summary: summary
        )
    }
}
