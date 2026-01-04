# X.02 - Calendar Tools

**Epic:** Tools
**Status:** Implemented
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** X.01 (Tool Protocol - Complete), F.02 (Permissions - Complete)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement calendar tools using EventKit for querying, finding slots, creating, editing, and deleting events. These tools enable Ora to be a practical calendar assistant.

---

## 2. User Story

As a **user**, I want Ora to **manage my calendar** so that I can **schedule meetings, check availability, and modify events using voice**.

---

## 3. Architecture Context & Reuse Guidance

### 3.1 Existing Infrastructure (MUST REUSE)

| Component | Location | Purpose |
|:----------|:---------|:--------|
| `Tool` protocol | `Ora/Tools/ToolProtocol.swift` | Base protocol all tools implement |
| `ToolRegistry` | `Ora/Tools/ToolRegistry.swift` | Register tools at startup |
| `ToolHost` | `Ora/Tools/ToolHost.swift` | Executes tools with confirmation gates + audit |
| `JSONValue` | `Ora/LLM/LLMOutput.swift` | Argument type for tool parameters |
| `ToolResult` | `Ora/Tools/ToolProtocol.swift` | Return type with JSON + human summary |
| `EventKitPermission` | `Ora/Permissions/EventKitPermission.swift` | Calendar permission checks |
| `AuditLogger` | `Ora/Persistence/AuditLogger.swift` | Automatic logging via ToolHost |

### 3.2 EventKit Patterns

From Apple EventKit documentation:

```swift
// EKEventStore is the gateway - create once, reuse
let store = EKEventStore()

// Query events in date range
let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
let events = store.events(matching: predicate)

// Get event by ID (for edit/delete)
let event = store.event(withIdentifier: eventID)

// Save changes (create or update)
try store.save(event, span: .thisEvent, commit: true)

// Delete
try store.remove(event, span: .thisEvent, commit: true)
```

**Key EKEvent mutable properties:**
- `title: String`
- `startDate: Date`
- `endDate: Date`
- `location: String?`
- `notes: String?`
- `calendar: EKCalendar`
- `isAllDay: Bool`
- `url: URL?`
- `alarms: [EKAlarm]?`
- `availability: EKEventAvailability`

**EKSpan for recurring events:**
- `.thisEvent` - Only this occurrence
- `.futureEvents` - This and all future occurrences

### 3.3 Guardrails Pattern

From `ToolProtocol.swift`:
- `kind: .read` → No confirmation required (query, find_slots)
- `kind: .mutate` → Requires confirmation (create, edit, delete)

The `ToolHost` automatically enforces this - if `tool.requiresConfirmation && !confirmed`, it throws `ToolHostError.confirmationRequired`.

---

## 4. Tools

| Tool | Kind | Description | Confirmation |
|:-----|:-----|:------------|:-------------|
| `calendar.query` | read | Query events in a date range | No |
| `calendar.find_slots` | read | Find available time slots | No |
| `calendar.create_event` | mutate | Create a new event | **Yes** |
| `calendar.edit_event` | mutate | Edit an existing event | **Yes** |
| `calendar.delete_event` | mutate | Delete an existing event | **Yes** |

---

## 5. File Touch List

### Files to Create

| File | Rationale |
|:-----|:----------|
| `Ora/Tools/Calendar/CalendarQueryTool.swift` | Query events by date range |
| `Ora/Tools/Calendar/CalendarFindSlotsTool.swift` | Find free time slots |
| `Ora/Tools/Calendar/CalendarCreateEventTool.swift` | Create new events |
| `Ora/Tools/Calendar/CalendarEditEventTool.swift` | Edit existing events (NEW) |
| `Ora/Tools/Calendar/CalendarDeleteEventTool.swift` | Delete events |
| `Ora/Tools/Calendar/CalendarToolErrors.swift` | Shared error types |
| `Ora/Tools/Calendar/EventStoreProvider.swift` | Shared EKEventStore access |
| `OraTests/Tools/Calendar/CalendarToolsTests.swift` | Unit tests for all calendar tools |

### Files to Modify

| File | Change |
|:-----|:-------|
| `Ora/Tools/ToolRegistry.swift` | Register calendar tools in `registerDefaultTools()` |
| `project.yml` | Add `Ora/Tools/Calendar/` folder to sources (if not auto-discovered) |

---

## 6. Implementation Plan

### Step 1: Create Shared Infrastructure

**File:** `Ora/Tools/Calendar/EventStoreProvider.swift`

```swift
//
//  EventStoreProvider.swift
//  Ora
//
//  Shared EKEventStore provider for calendar tools
//

import EventKit

/// Provides shared access to EKEventStore
enum EventStoreProvider {
    /// Shared event store instance
    /// Note: EKEventStore is thread-safe and meant to be reused
    static let shared = EKEventStore()
    
    /// ISO8601 date formatter with fractional seconds
    static var dateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
    
    /// Fallback formatter without fractional seconds
    static var dateFormatterNoFractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
    
    /// Parse ISO8601 date string with fallback
    static func parseDate(_ string: String) -> Date? {
        dateFormatter.date(from: string) ?? dateFormatterNoFractional.date(from: string)
    }
    
    /// Format date to ISO8601 string
    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
```

**File:** `Ora/Tools/Calendar/CalendarToolErrors.swift`

```swift
//
//  CalendarToolErrors.swift
//  Ora
//
//  Error types for calendar tools
//

import Foundation

enum CalendarToolError: LocalizedError {
    case invalidDateFormat(String)
    case eventNotFound(String)
    case endBeforeStart
    case noDefaultCalendar
    case permissionDenied
    case saveFailed(String)
    case deleteFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidDateFormat(let value):
            return "Invalid date format: \(value). Use ISO 8601 format."
        case .eventNotFound(let id):
            return "Event not found: \(id)"
        case .endBeforeStart:
            return "End time must be after start time."
        case .noDefaultCalendar:
            return "No default calendar available."
        case .permissionDenied:
            return "Calendar access denied. Please grant permission in System Settings."
        case .saveFailed(let reason):
            return "Failed to save event: \(reason)"
        case .deleteFailed(let reason):
            return "Failed to delete event: \(reason)"
        }
    }
}
```

### Step 2: Implement Query Tool

**File:** `Ora/Tools/Calendar/CalendarQueryTool.swift`

```swift
//
//  CalendarQueryTool.swift
//  Ora
//
//  Query calendar events in a date range
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
        
        let eventData: [JSONValue] = events.map { event in
            .object([
                "id": .string(event.eventIdentifier),
                "title": .string(event.title ?? ""),
                "start": .string(EventStoreProvider.formatDate(event.startDate)),
                "end": .string(EventStoreProvider.formatDate(event.endDate)),
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
```

### Step 3: Implement Find Slots Tool

**File:** `Ora/Tools/Calendar/CalendarFindSlotsTool.swift`

```swift
//
//  CalendarFindSlotsTool.swift
//  Ora
//
//  Find available time slots in a date range
//

import Foundation
import EventKit

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
        guard args["start"]?.stringValue != nil else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: start")
        }
        guard args["end"]?.stringValue != nil else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: end")
        }
        guard args["duration_minutes"]?.numberValue != nil else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: duration_minutes")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
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
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        
        // Find gaps
        var slots: [(start: Date, end: Date)] = []
        var cursor = start
        
        for event in events {
            if event.startDate > cursor {
                let gapEnd = event.startDate
                let gapDuration = gapEnd.timeIntervalSince(cursor)
                if gapDuration >= duration {
                    slots.append((cursor, cursor.addingTimeInterval(duration)))
                    if slots.count >= maxResults { break }
                }
            }
            if event.endDate > cursor {
                cursor = event.endDate
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
```

### Step 4: Implement Create Event Tool

**File:** `Ora/Tools/Calendar/CalendarCreateEventTool.swift`

```swift
//
//  CalendarCreateEventTool.swift
//  Ora
//
//  Create new calendar events (requires confirmation)
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
        let store = EventStoreProvider.shared
        
        guard let title = args["title"]?.stringValue,
              let startStr = args["start"]?.stringValue,
              let endStr = args["end"]?.stringValue,
              let start = EventStoreProvider.parseDate(startStr),
              let end = EventStoreProvider.parseDate(endStr) else {
            throw CalendarToolError.invalidDateFormat("title, start, or end")
        }
        
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
        } else {
            guard let defaultCalendar = store.defaultCalendarForNewEvents else {
                throw CalendarToolError.noDefaultCalendar
            }
            event.calendar = defaultCalendar
        }
        
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
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
```

### Step 5: Implement Edit Event Tool (NEW)

**File:** `Ora/Tools/Calendar/CalendarEditEventTool.swift`

```swift
//
//  CalendarEditEventTool.swift
//  Ora
//
//  Edit existing calendar events (requires confirmation)
//

import Foundation
import EventKit

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
```

### Step 6: Implement Delete Event Tool

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
```

### Step 7: Register Tools

**Modify:** `Ora/Tools/ToolRegistry.swift`

Add to `registerDefaultTools()`:

```swift
func registerDefaultTools() {
    // Calendar tools
    register(CalendarQueryTool())
    register(CalendarFindSlotsTool())
    register(CalendarCreateEventTool())
    register(CalendarEditEventTool())
    register(CalendarDeleteEventTool())
    
    logger.info("Registered \(self.tools.count) tools")
}
```

---

## 7. Tests and Validation

### 7.1 Unit Tests

**File:** `OraTests/Tools/Calendar/CalendarToolsTests.swift`

```swift
import XCTest
@testable import Ora

final class CalendarToolsTests: XCTestCase {
    
    // MARK: - Query Tool Tests
    
    func test_queryTool_validate_missingStart() async throws {
        let tool = CalendarQueryTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "end": .string("2026-01-02T00:00:00Z")
        ]))
    }
    
    func test_queryTool_validate_invalidDateFormat() async throws {
        let tool = CalendarQueryTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "start": .string("not-a-date"),
            "end": .string("2026-01-02T00:00:00Z")
        ]))
    }
    
    func test_queryTool_schema() {
        let tool = CalendarQueryTool()
        XCTAssertEqual(tool.name, "calendar.query")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
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
    
    func test_createTool_validate_endBeforeStart() {
        let tool = CalendarCreateEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "title": .string("Meeting"),
            "start": .string("2026-01-15T11:00:00Z"),
            "end": .string("2026-01-15T10:00:00Z")
        ])) { error in
            XCTAssertTrue(error is CalendarToolError)
        }
    }
    
    func test_createTool_requiresConfirmation() {
        let tool = CalendarCreateEventTool()
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.kind, .mutate)
    }
    
    // MARK: - Edit Event Tool Tests
    
    func test_editTool_validate_success() throws {
        let tool = CalendarEditEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345")
        ]))
    }
    
    func test_editTool_validate_missingEventID() {
        let tool = CalendarEditEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [:]))
    }
    
    func test_editTool_validate_invalidSpan() {
        let tool = CalendarEditEventTool()
        
        XCTAssertThrowsError(try tool.validate(args: [
            "event_id": .string("12345"),
            "span": .string("invalid")
        ]))
    }
    
    func test_editTool_requiresConfirmation() {
        let tool = CalendarEditEventTool()
        XCTAssertTrue(tool.requiresConfirmation)
        XCTAssertEqual(tool.kind, .mutate)
    }
    
    // MARK: - Delete Event Tool Tests
    
    func test_deleteTool_validate_success() throws {
        let tool = CalendarDeleteEventTool()
        
        XCTAssertNoThrow(try tool.validate(args: [
            "event_id": .string("12345")
        ]))
    }
    
    func test_deleteTool_requiresConfirmation() {
        let tool = CalendarDeleteEventTool()
        XCTAssertTrue(tool.requiresConfirmation)
    }
    
    // MARK: - Find Slots Tool Tests
    
    func test_findSlotsTool_schema() {
        let tool = CalendarFindSlotsTool()
        XCTAssertEqual(tool.name, "calendar.find_slots")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
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
    
    func test_parseDate_invalid() {
        let date = EventStoreProvider.parseDate("not-a-date")
        XCTAssertNil(date)
    }
}
```

### 7.2 Manual Tests

| Test | Steps | Expected |
|:-----|:------|:---------|
| Query events | Ask "What's on my calendar tomorrow?" | Returns events or "no events" |
| Find slots | Ask "Find a 30 minute slot this afternoon" | Returns available times |
| Create event | Ask "Schedule a meeting with John at 3pm tomorrow" | Proposes, confirms, creates |
| Edit event | Ask "Move my 3pm meeting to 4pm" | Proposes edit, confirms, updates |
| Delete event | Ask "Cancel my 3pm meeting" | Proposes deletion, confirms, removes |
| Recurring event | Ask "Delete all future instances of standup" | Uses span=future |

---

## 8. Acceptance Criteria

- [x] **AC-1:** `calendar.query` returns events in date range with proper JSON structure ✅ Verified in `CalendarQueryTool.swift`
- [x] **AC-2:** `calendar.find_slots` finds available time gaps ✅ Verified in `CalendarFindSlotsTool.swift`
- [x] **AC-3:** `calendar.create_event` creates events with all fields (title, dates, location, notes) ✅ Verified in `CalendarCreateEventTool.swift`
- [x] **AC-4:** `calendar.edit_event` updates only provided fields, preserves others ✅ Verified in `CalendarEditEventTool.swift`
- [x] **AC-5:** `calendar.delete_event` removes event by ID ✅ Verified in `CalendarDeleteEventTool.swift`
- [x] **AC-6:** All mutations (`create`, `edit`, `delete`) require confirmation via ToolHost ✅ `kind: .mutate` enforces confirmation
- [x] **AC-7:** Human summaries are clear and concise for TTS ✅ Each tool returns descriptive `humanSummary`
- [x] **AC-8:** Recurring events use `span` parameter correctly ✅ Verified in edit and delete tools
- [x] **AC-9:** All tools registered in `ToolRegistry.registerDefaultTools()` ✅ Verified by `test_calendarToolsRegistered`
- [x] **AC-10:** Unit tests pass for validation and schema ✅ 40 tests in `CalendarToolsTests.swift`

---

## 9. Risks and Open Questions

### Risks

| Risk | Mitigation |
|:-----|:-----------|
| Calendar permission denied at runtime | Tools should throw `CalendarToolError.permissionDenied` with helpful message |
| Event ID becomes stale (event deleted externally) | Handle `eventNotFound` gracefully |
| Recurring events: user doesn't specify which instances | Default to `span: .thisEvent`, require explicit "all future" |
| EKEventStore threading | EKEventStore is thread-safe, but we create shared instance |

### Open Questions

1. **Should edit support clearing fields?** (e.g., remove location) - Currently only sets if provided
2. **Should we return calendar list tool?** - Users might want to pick which calendar
3. **Should find_slots respect working hours?** - Currently finds any free time

---

## 10. Future Enhancements (Out of Scope)

- [ ] `calendar.list_calendars` - List available calendars
- [ ] Attendee management (invites)
- [ ] Recurrence rule creation
- [ ] Travel time between events
- [ ] Smart scheduling (respect working hours, lunch)

---

## Implementation Summary

**Date:** 2026-01-03
**Branch:** `feat/x.02-calendar-tools`
**Commits:** 1

### Files Created

| File | Purpose |
|:-----|:--------|
| `Ora/Tools/Calendar/EventStoreProvider.swift` | Shared EKEventStore access, ISO8601 date parsing |
| `Ora/Tools/Calendar/CalendarToolErrors.swift` | Error types for calendar operations |
| `Ora/Tools/Calendar/CalendarQueryTool.swift` | Query events in date range (read) |
| `Ora/Tools/Calendar/CalendarFindSlotsTool.swift` | Find available time slots (read) |
| `Ora/Tools/Calendar/CalendarCreateEventTool.swift` | Create new events (mutate, requires confirmation) |
| `Ora/Tools/Calendar/CalendarEditEventTool.swift` | Edit existing events (mutate, requires confirmation) |
| `Ora/Tools/Calendar/CalendarDeleteEventTool.swift` | Delete events (mutate, requires confirmation) |
| `OraTests/Tools/Calendar/CalendarToolsTests.swift` | 40 unit tests for validation, schemas, registration |

### Files Modified

| File | Change |
|:-----|:-------|
| `Ora/Tools/ToolRegistry.swift` | Register all 5 calendar tools in `registerDefaultTools()` |

### Implementation Notes

1. **Concurrency:** Used `@preconcurrency import EventKit` and `nonisolated(unsafe)` for shared EKEventStore to satisfy Swift 6 strict concurrency
2. **Optional Handling:** EKEvent.startDate/endDate are optional in Swift, added proper unwrapping
3. **Test Coverage:** Comprehensive unit tests for validation logic, schema properties, and tool registration
4. **Pre-existing Test Failures:** 4 tests in `HuggingFaceDownloaderTests` fail due to unrelated network/download issues

### Ready for Review

- [x] All acceptance criteria verified
- [x] Tests passing (638 tests, 4 pre-existing failures unrelated to calendar)
- [x] Working tree clean

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-03T09:08:23Z
**Commit reviewed:** b9c4aeafc3bcf8bd628909dc881d0bf52eb4e8c0
**Iteration:** 1

### Summary
- Files reviewed: 10
- Build status: Pass
- Tests status: Pass (638 tests, 3 pre-existing failures in HuggingFaceDownloaderTests - unrelated to calendar tools)

### Issues Found

#### P0 - Critical (Must fix)

*None*

#### P1 - Major (Should fix)

*None*

#### P2 - Minor (Can defer)

- [ ] `CalendarFindSlotsTool.swift:31-38` - Inconsistent date validation in `validate()`. Unlike `CalendarQueryTool` and `CalendarCreateEventTool`, this tool only checks for parameter existence but does not validate the date format with `EventStoreProvider.parseDate()`. The validation will still fail in `execute()` if the date is invalid, but for consistency with other tools, consider adding date format validation in `validate()`.

### Future Considerations (Out of Scope)

- Pre-existing test failures in `HuggingFaceDownloaderTests` are unrelated to this PR and caused by network/download verification issues.

### Approval Status

- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## Code Review Findings

**Reviewer:** Codex Subagent
**Date:** 2026-01-03T09:13:22Z
**Commit reviewed:** de0684436fe3caa89e6cdbed746a15059b8b0896
**Iteration:** 2

### Summary
- Files reviewed: 10
- Build status: Pass
- Tests status: Pass (640 tests, 1 skipped, 3 pre-existing failures in HuggingFaceDownloaderTests - unrelated to calendar tools)

### Issues Found

#### P0 - Critical (Must fix)

*None*

#### P1 - Major (Should fix)

*None*

#### P2 - Minor (Can defer)

*None* - Previous P2 issue (inconsistent date validation in `CalendarFindSlotsTool.swift`) has been fixed. The `validate()` function now validates date formats using `EventStoreProvider.parseDate()` at lines 40-46, consistent with all other calendar tools.

### Verification of Previous P2 Fix

The `CalendarFindSlotsTool.swift` validate() function now includes:
```swift
guard EventStoreProvider.parseDate(startStr) != nil else {
    throw CalendarToolError.invalidDateFormat(startStr)
}
guard EventStoreProvider.parseDate(endStr) != nil else {
    throw CalendarToolError.invalidDateFormat(endStr)
}
```

This matches the pattern used in `CalendarQueryTool` and `CalendarCreateEventTool`.

### Future Considerations (Out of Scope)

- Pre-existing test failures in `HuggingFaceDownloaderTests` are unrelated to this PR and caused by network/download verification issues.

### Approval Status

- [x] All P0 issues resolved
- [x] All P1 issues resolved
- [x] Ready for merge

---

## Implementation Learnings (Post-Merge)

**Date:** 2026-01-04

### Critical: Tool Result Context for Multi-Step Flows

When implementing tools that require multi-step agentic flows (e.g., query → delete), the **AgentLoop must pass full JSON data to the LLM**, not just the human summary.

**Problem:** The LLM was unable to delete events because it never saw the event IDs. The `AgentLoop` was only passing `humanSummary` ("Found 3 events.") to the conversation context.

**Solution:** Pass compact JSON data so the LLM can see details like event IDs:

```swift
// WRONG - LLM can't see event IDs for subsequent operations
let resultText = "Tool \(tool) returned: \(result.humanSummary)"

// CORRECT - Include full JSON so LLM can reference data in next steps
let jsonString = result.json.compactJSON
let resultText = "Tool \(tool) returned: \(jsonString)"
```

**Added to LLMOutput.swift:**
```swift
extension JSONValue {
    var compactJSON: String {
        // Compact single-line JSON, no extra whitespace
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? stringDescription
    }
}
```

**System prompt instruction added:**
> "IMPORTANT: To edit or delete an event, you MUST first query events using calendar.query to get the real event_id. Never invent or guess event IDs."

### Key Takeaway for All Tools

Any tool that returns data needed for subsequent operations (IDs, identifiers, references) must:
1. Include those IDs in the `json` field of `ToolResult`
2. Rely on the AgentLoop passing full JSON to conversation context
3. Instruct the LLM in the system prompt to query first if needed
