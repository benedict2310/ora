# X.02 - Calendar Tools

**Epic:** Tools
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2 days
**Dependencies:** X.01 (Tool Protocol), F.02 (Permissions)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement calendar tools using EventKit for querying, finding slots, creating, and deleting events.

---

## 2. Tools

| Tool | Kind | Description |
|:-----|:-----|:------------|
| `calendar.query` | read | Query events in a date range |
| `calendar.find_slots` | read | Find available time slots |
| `calendar.create_event` | mutate | Create a new event |
| `calendar.delete_event` | mutate | Delete an existing event |

---

## 3. Implementation

### 3.1 Calendar Query Tool

**File:** `Ora/Tools/Calendar/CalendarQueryTool.swift`

```swift
//
//  CalendarQueryTool.swift
//  Ora
//
//  Query calendar events
//

import Foundation
import EventKit

struct CalendarQueryTool: Tool {
    let name = "calendar.query"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Query calendar events within a date range",
            parameters: [
                "start": ParameterSchema(type: "string", description: "Start date/time (ISO 8601)", format: "date-time"),
                "end": ParameterSchema(type: "string", description: "End date/time (ISO 8601)", format: "date-time"),
                "calendar_id": ParameterSchema(type: "string", description: "Optional calendar ID", format: nil)
            ],
            requiredParameters: ["start", "end"]
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard args["start"]?.stringValue != nil else {
            throw ToolValidationError.missingParameter("start")
        }
        guard args["end"]?.stringValue != nil else {
            throw ToolValidationError.missingParameter("end")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let store = EKEventStore()
        
        guard let startStr = args["start"]?.stringValue,
              let endStr = args["end"]?.stringValue,
              let start = ISO8601DateFormatter().date(from: startStr),
              let end = ISO8601DateFormatter().date(from: endStr) else {
            throw ToolExecutionError.invalidArgument("Invalid date format")
        }
        
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        
        let eventData: [JSONValue] = events.map { event in
            .object([
                "id": .string(event.eventIdentifier),
                "title": .string(event.title ?? ""),
                "start": .string(ISO8601DateFormatter().string(from: event.startDate)),
                "end": .string(ISO8601DateFormatter().string(from: event.endDate)),
                "location": .string(event.location ?? ""),
                "calendar": .string(event.calendar.title)
            ])
        }
        
        let summary = events.isEmpty 
            ? "No events found in that time range."
            : "Found \(events.count) event\(events.count == 1 ? "" : "s")."
        
        return .success(.array(eventData), summary: summary)
    }
}
```

### 3.2 Calendar Create Event Tool

**File:** `Ora/Tools/Calendar/CalendarCreateEventTool.swift`

```swift
//
//  CalendarCreateEventTool.swift
//  Ora
//
//  Create calendar events (requires confirmation)
//

import Foundation
import EventKit

struct CalendarCreateEventTool: Tool {
    let name = "calendar.create_event"
    let kind: ToolKind = .mutate
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create a new calendar event. Requires confirmation.",
            parameters: [
                "title": ParameterSchema(type: "string", description: "Event title", format: nil),
                "start": ParameterSchema(type: "string", description: "Start date/time (ISO 8601)", format: "date-time"),
                "end": ParameterSchema(type: "string", description: "End date/time (ISO 8601)", format: "date-time"),
                "location": ParameterSchema(type: "string", description: "Event location", format: nil),
                "notes": ParameterSchema(type: "string", description: "Event notes", format: nil),
                "calendar_id": ParameterSchema(type: "string", description: "Calendar ID (uses default if omitted)", format: nil)
            ],
            requiredParameters: ["title", "start", "end"]
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let title = args["title"]?.stringValue, !title.isEmpty else {
            throw ToolValidationError.missingParameter("title")
        }
        guard args["start"]?.stringValue != nil else {
            throw ToolValidationError.missingParameter("start")
        }
        guard args["end"]?.stringValue != nil else {
            throw ToolValidationError.missingParameter("end")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let store = EKEventStore()
        
        guard let title = args["title"]?.stringValue,
              let startStr = args["start"]?.stringValue,
              let endStr = args["end"]?.stringValue,
              let start = ISO8601DateFormatter().date(from: startStr),
              let end = ISO8601DateFormatter().date(from: endStr) else {
            throw ToolExecutionError.invalidArgument("Invalid arguments")
        }
        
        // Validate end > start
        guard end > start else {
            throw ToolExecutionError.invalidArgument("End time must be after start time")
        }
        
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = args["location"]?.stringValue
        event.notes = args["notes"]?.stringValue
        
        // Set calendar
        if let calendarID = args["calendar_id"]?.stringValue,
           let calendar = store.calendar(withIdentifier: calendarID) {
            event.calendar = calendar
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }
        
        try store.save(event, span: .thisEvent, commit: true)
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        let summary = "Created '\(title)' on \(formatter.string(from: start))."
        
        return .success(
            .object(["event_id": .string(event.eventIdentifier)]),
            summary: summary
        )
    }
}
```

### 3.3 Calendar Delete Event Tool

**File:** `Ora/Tools/Calendar/CalendarDeleteEventTool.swift`

```swift
//
//  CalendarDeleteEventTool.swift
//  Ora
//
//  Delete calendar events (requires confirmation)
//

import Foundation
import EventKit

struct CalendarDeleteEventTool: Tool {
    let name = "calendar.delete_event"
    let kind: ToolKind = .mutate
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Delete a calendar event. Requires confirmation.",
            parameters: [
                "event_id": ParameterSchema(type: "string", description: "Event identifier", format: nil)
            ],
            requiredParameters: ["event_id"]
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard args["event_id"]?.stringValue != nil else {
            throw ToolValidationError.missingParameter("event_id")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let store = EKEventStore()
        
        guard let eventID = args["event_id"]?.stringValue,
              let event = store.event(withIdentifier: eventID) else {
            throw ToolExecutionError.notFound("Event not found")
        }
        
        let title = event.title ?? "Untitled"
        try store.remove(event, span: .thisEvent, commit: true)
        
        return .success(
            .object(["deleted": .bool(true)]),
            summary: "Deleted '\(title)'."
        )
    }
}
```

---

## 4. Acceptance Criteria

- [ ] **AC-1:** Query returns events in date range
- [ ] **AC-2:** Create adds event with all fields
- [ ] **AC-3:** Delete removes event by ID
- [ ] **AC-4:** Mutations require confirmation (via ToolHost)
- [ ] **AC-5:** Human summaries are clear and concise

---

## 5. Implementation Checklist

- [ ] Create `CalendarQueryTool.swift`
- [ ] Create `CalendarFindSlotsTool.swift`
- [ ] Create `CalendarCreateEventTool.swift`
- [ ] Create `CalendarDeleteEventTool.swift`
- [ ] Register in `ToolRegistry`
- [ ] Test with real calendar data
