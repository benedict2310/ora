//
//  CalendarDeleteEventTool.swift
//  Ora
//
//  Delete calendar events (requires confirmation)
//

import Foundation
@preconcurrency import EventKit

struct CalendarDeleteEventTool: Tool {
    let name = "calendar.delete_event"
    let kind: ToolKind = .mutate
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Delete a calendar event. Requires confirmation.",
            parameters: [
                "event_id": ParameterSchema(type: "string", description: "Event identifier (from query)"),
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
        
        if let span = args["span"]?.stringValue {
            guard span == "this" || span == "future" else {
                throw ToolHostError.validationFailed(name, "span must be 'this' or 'future'")
            }
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let store = EventStoreProvider.shared
        
        guard let eventID = args["event_id"]?.stringValue,
              let event = store.event(withIdentifier: eventID) else {
            throw CalendarToolError.eventNotFound(args["event_id"]?.stringValue ?? "nil")
        }
        
        let title = event.title ?? "Untitled"
        
        let span: EKSpan
        if let spanStr = args["span"]?.stringValue, spanStr == "future" {
            span = .futureEvents
        } else {
            span = .thisEvent
        }
        
        do {
            try store.remove(event, span: span, commit: true)
        } catch {
            throw CalendarToolError.deleteFailed(error.localizedDescription)
        }
        
        return .success(
            .object([
                "deleted": .bool(true),
                "title": .string(title)
            ]),
            summary: "Deleted '\(title)'."
        )
    }
}
