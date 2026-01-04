//
//  CalendarFindSlotsTool.swift
//  Ora
//
//  Find available time slots in a date range
//

import Foundation
@preconcurrency import EventKit

struct CalendarFindSlotsTool: Tool {
    let name = "calendar.find_slots"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Find available time slots of a given duration within a date range",
            parameters: [
                "start": ParameterSchema(type: "string", description: "Start of search range (ISO 8601)", format: "date-time"),
                "end": ParameterSchema(type: "string", description: "End of search range (ISO 8601)", format: "date-time"),
                "duration_minutes": ParameterSchema(type: "number", description: "Required slot duration in minutes"),
                "max_results": ParameterSchema(type: "number", description: "Maximum slots to return (default 5)")
            ],
            requiredParameters: ["start", "end", "duration_minutes"],
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
        guard args["duration_minutes"]?.numberValue != nil else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: duration_minutes")
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
              let end = EventStoreProvider.parseDate(endStr),
              let durationMinutes = args["duration_minutes"]?.numberValue else {
            throw CalendarToolError.invalidDateFormat("start, end, or duration")
        }
        
        let duration = durationMinutes * 60  // Convert to seconds
        let maxResults = Int(args["max_results"]?.numberValue ?? 5)
        
        // Get existing events
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        
        // Find gaps
        var slots: [(start: Date, end: Date)] = []
        var cursor = start
        
        for event in events {
            guard let eventStart = event.startDate, let eventEnd = event.endDate else {
                continue
            }
            if eventStart > cursor {
                let gapEnd = eventStart
                let gapDuration = gapEnd.timeIntervalSince(cursor)
                if gapDuration >= duration {
                    slots.append((cursor, cursor.addingTimeInterval(duration)))
                    if slots.count >= maxResults { break }
                }
            }
            if eventEnd > cursor {
                cursor = eventEnd
            }
        }
        
        // Check for slot after last event
        if slots.count < maxResults && cursor < end {
            let gapDuration = end.timeIntervalSince(cursor)
            if gapDuration >= duration {
                slots.append((cursor, cursor.addingTimeInterval(duration)))
            }
        }
        
        let slotData: [JSONValue] = slots.map { slot in
            .object([
                "start": .string(EventStoreProvider.formatDate(slot.start)),
                "end": .string(EventStoreProvider.formatDate(slot.end))
            ])
        }
        
        let summary: String
        if slots.isEmpty {
            summary = "No available slots found for \(Int(durationMinutes)) minutes."
        } else if slots.count == 1 {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            summary = "Found 1 available slot at \(formatter.string(from: slots[0].start))."
        } else {
            summary = "Found \(slots.count) available slots."
        }
        
        return .success(.array(slotData), summary: summary)
    }
}
