//
//  CalendarEditEventTool.swift
//  Ora
//
//  Edit existing calendar events (requires confirmation)
//

import Foundation
@preconcurrency import EventKit

struct CalendarEditEventTool: Tool {
    let name = "calendar.edit_event"
    let kind: ToolKind = .mutate
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Edit an existing calendar event. Requires confirmation. Only provided fields are updated.",
            parameters: [
                "event_id": ParameterSchema(type: "string", description: "Event identifier (from query)"),
                "title": ParameterSchema(type: "string", description: "New event title (optional)"),
                "start": ParameterSchema(type: "string", description: "New start date/time (ISO 8601, optional)", format: "date-time"),
                "end": ParameterSchema(type: "string", description: "New end date/time (ISO 8601, optional)", format: "date-time"),
                "location": ParameterSchema(type: "string", description: "New event location (optional)"),
                "notes": ParameterSchema(type: "string", description: "New event notes (optional)"),
                "span": ParameterSchema(type: "string", description: "For recurring: 'this' or 'future' (default: 'this')")
            ],
            requiredParameters: ["event_id"],
            requiresConfirmation: true
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let eventID = args["event_id"]?.stringValue, !eventID.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: event_id")
        }
        
        // Validate date formats if provided
        if let startStr = args["start"]?.stringValue {
            guard EventStoreProvider.parseDate(startStr) != nil else {
                throw CalendarToolError.invalidDateFormat(startStr)
            }
        }
        if let endStr = args["end"]?.stringValue {
            guard EventStoreProvider.parseDate(endStr) != nil else {
                throw CalendarToolError.invalidDateFormat(endStr)
            }
        }
        
        // Validate span if provided
        if let span = args["span"]?.stringValue {
            guard span == "this" || span == "future" else {
                throw ToolHostError.validationFailed(name, "span must be 'this' or 'future'")
            }
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        // Check calendar permission first
        try await EventStoreProvider.ensureCalendarAccess()
        
        let store = EventStoreProvider.shared
        
        guard let eventID = args["event_id"]?.stringValue,
              let event = store.event(withIdentifier: eventID) else {
            throw CalendarToolError.eventNotFound(args["event_id"]?.stringValue ?? "nil")
        }
        
        let originalTitle = event.title ?? "Untitled"
        var changes: [String] = []
        
        // Apply updates only for provided fields
        if let title = args["title"]?.stringValue {
            event.title = title
            changes.append("title")
        }
        
        if let startStr = args["start"]?.stringValue,
           let start = EventStoreProvider.parseDate(startStr) {
            event.startDate = start
            changes.append("start time")
        }
        
        if let endStr = args["end"]?.stringValue,
           let end = EventStoreProvider.parseDate(endStr) {
            event.endDate = end
            changes.append("end time")
        }
        
        if let location = args["location"]?.stringValue {
            event.location = location
            changes.append("location")
        }
        
        if let notes = args["notes"]?.stringValue {
            event.notes = notes
            changes.append("notes")
        }
        
        // Validate end > start after updates
        if event.endDate <= event.startDate {
            throw CalendarToolError.endBeforeStart
        }
        
        // Determine span for recurring events
        let span: EKSpan
        if let spanStr = args["span"]?.stringValue, spanStr == "future" {
            span = .futureEvents
        } else {
            span = .thisEvent
        }
        
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw CalendarToolError.saveFailed(error.localizedDescription)
        }
        
        let changesText = changes.isEmpty ? "no fields" : changes.joined(separator: ", ")
        let summary = "Updated '\(originalTitle)': \(changesText)."
        
        return .success(
            .object([
                "event_id": .string(event.eventIdentifier),
                "updated_fields": .array(changes.map { .string($0) })
            ]),
            summary: summary
        )
    }
}
