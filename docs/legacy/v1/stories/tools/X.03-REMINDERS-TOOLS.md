# X.03 - Reminders Tools

**Epic:** Tools
**Status:** Complete
**Priority:** P1 (Important)
**Estimated Effort:** 1 day
**Dependencies:** X.01 (Tool Protocol), F.02 (Permissions)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement reminders tools using EventKit for listing, creating, and completing reminders.

---

## 2. Tools

| Tool | Kind | Description |
|:-----|:-----|:------------|
| `reminders.list` | read | List reminders, optionally by list |
| `reminders.create` | mutate | Create a new reminder |
| `reminders.complete` | mutate | Mark reminder as complete |
| `reminders.edit` | mutate | Edit an existing reminder |

---

## 3. Implementation

### 3.1 Reminders List Tool

**File:** `Ora/Tools/Reminders/RemindersListTool.swift`

```swift
//
//  RemindersListTool.swift
//  Ora
//
//  List reminders
//

import Foundation
import EventKit

struct RemindersListTool: Tool {
    let name = "reminders.list"
    let kind: ToolKind = .read
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List reminders, optionally filtered by list or completion status",
            parameters: [
                "list_name": ParameterSchema(type: "string", description: "Filter by list name", format: nil),
                "include_completed": ParameterSchema(type: "boolean", description: "Include completed reminders", format: nil)
            ],
            requiredParameters: []
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        // No required parameters
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let store = EKEventStore()
        let includeCompleted = args["include_completed"]?.boolValue ?? false
        
        let calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForReminders(in: calendars)
        
        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        
        var filtered = reminders
        if !includeCompleted {
            filtered = reminders.filter { !$0.isCompleted }
        }
        
        if let listName = args["list_name"]?.stringValue {
            filtered = filtered.filter { $0.calendar.title.lowercased().contains(listName.lowercased()) }
        }
        
        let reminderData: [JSONValue] = filtered.prefix(20).map { reminder in
            .object([
                "id": .string(reminder.calendarItemIdentifier),
                "title": .string(reminder.title ?? ""),
                "due_date": reminder.dueDateComponents.flatMap { 
                    Calendar.current.date(from: $0) 
                }.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "completed": .bool(reminder.isCompleted),
                "list": .string(reminder.calendar.title)
            ])
        }
        
        let summary = filtered.isEmpty 
            ? "No reminders found."
            : "Found \(filtered.count) reminder\(filtered.count == 1 ? "" : "s")."
        
        return .success(.array(reminderData), summary: summary)
    }
}
```

### 3.2 Reminders Create Tool

**File:** `Ora/Tools/Reminders/RemindersCreateTool.swift`

```swift
//
//  RemindersCreateTool.swift
//  Ora
//
//  Create reminders (requires confirmation)
//

import Foundation
import EventKit

struct RemindersCreateTool: Tool {
    let name = "reminders.create"
    let kind: ToolKind = .mutate
    
    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create a new reminder. Requires confirmation.",
            parameters: [
                "title": ParameterSchema(type: "string", description: "Reminder title", format: nil),
                "due_date": ParameterSchema(type: "string", description: "Due date (ISO 8601)", format: "date-time"),
                "list_name": ParameterSchema(type: "string", description: "Reminders list name", format: nil),
                "notes": ParameterSchema(type: "string", description: "Additional notes", format: nil)
            ],
            requiredParameters: ["title"]
        )
    }
    
    func validate(args: [String: JSONValue]) throws {
        guard let title = args["title"]?.stringValue, !title.isEmpty else {
            throw ToolValidationError.missingParameter("title")
        }
    }
    
    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        let store = EKEventStore()
        
        guard let title = args["title"]?.stringValue else {
            throw ToolExecutionError.invalidArgument("Title required")
        }
        
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = args["notes"]?.stringValue
        
        // Set due date if provided
        if let dueDateStr = args["due_date"]?.stringValue,
           let dueDate = ISO8601DateFormatter().date(from: dueDateStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }
        
        // Find list by name or use default
        if let listName = args["list_name"]?.stringValue {
            let calendars = store.calendars(for: .reminder)
            if let calendar = calendars.first(where: { $0.title.lowercased() == listName.lowercased() }) {
                reminder.calendar = calendar
            }
        }
        
        if reminder.calendar == nil {
            reminder.calendar = store.defaultCalendarForNewReminders
        }
        
        try store.save(reminder, commit: true)
        
        var summary = "Created reminder '\(title)'"
        if let dueStr = args["due_date"]?.stringValue,
           let dueDate = ISO8601DateFormatter().date(from: dueStr) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            summary += " due \(formatter.string(from: dueDate))"
        }
        summary += "."
        
        return .success(
            .object(["reminder_id": .string(reminder.calendarItemIdentifier)]),
            summary: summary
        )
    }
}
```

---

## 4. Acceptance Criteria

- [x] **AC-1:** List returns incomplete reminders by default - ✅ `RemindersListTool.swift:94-96`
- [x] **AC-2:** Create adds reminder with optional due date - ✅ `RemindersCreateTool.swift:75-81`
- [x] **AC-3:** Complete marks reminder as done - ✅ `RemindersCompleteTool.swift:64-66`
- [x] **AC-4:** Mutations require confirmation - ✅ All mutate tools have `kind: .mutate`
- [x] **AC-5:** Edit modifies reminder fields - ✅ `RemindersEditTool.swift` (added per request)

---

## 5. Implementation Checklist

- [x] Create `RemindersStoreProvider.swift` - shared EventStore with permission handling
- [x] Create `RemindersToolErrors.swift` - error types for reminders tools
- [x] Create `RemindersListTool.swift` - list with filters
- [x] Create `RemindersCreateTool.swift` - create with due date, list, priority
- [x] Create `RemindersCompleteTool.swift` - mark as complete
- [x] Create `RemindersEditTool.swift` - edit title, due date, notes, priority, list
- [x] Register in `ToolRegistry` - 4 reminders tools registered
- [x] Unit tests in `RemindersToolsTests.swift` - 40 tests passing

---

## 6. Implementation Notes (From X.02 Learnings)

### Tool Result Context for Multi-Step Flows

When implementing tools that return IDs (like `reminder_id` in the create result), ensure:

1. **Include IDs in JSON:** The `ToolResult.json` must include the `id` field so the LLM can reference it in subsequent operations (e.g., marking complete after creation).

2. **AgentLoop handles context:** The `AgentLoop` passes `result.json.compactJSON` to the conversation context, not just the human summary. This is already implemented.

3. **System prompt guidance:** If the LLM needs to query before mutating (e.g., finding a reminder by name before completing it), add an instruction to the system prompt similar to:
   > "To complete or delete a reminder, you MUST first list reminders to get the reminder_id."

### Example Pattern

```swift
return .success(
    .object([
        "reminder_id": .string(reminder.calendarItemIdentifier),  // Critical for follow-up operations
        "title": .string(title),
        "list": .string(reminder.calendar.title)
    ]),
    summary: "Created reminder '\(title)'."
)
```

---

## 7. Implementation Summary

**Date:** 2026-01-06
**Branch:** `feat/X.03-reminders-tools`

### Files Created
- `Ora/Tools/Reminders/RemindersStoreProvider.swift` - Shared EKEventStore for reminders with permission handling
- `Ora/Tools/Reminders/RemindersToolErrors.swift` - Error types for reminders tools
- `Ora/Tools/Reminders/RemindersListTool.swift` - List reminders with filters (list name, include completed)
- `Ora/Tools/Reminders/RemindersCreateTool.swift` - Create reminders with due date, list, notes, priority
- `Ora/Tools/Reminders/RemindersCompleteTool.swift` - Mark reminders as complete
- `Ora/Tools/Reminders/RemindersEditTool.swift` - Edit reminder title, due date, notes, priority, list
- `OraTests/Tools/Reminders/RemindersToolsTests.swift` - 40 unit tests

### Files Modified
- `Ora/Tools/ToolRegistry.swift` - Register 4 reminders tools
- `OraTests/Tools/Calendar/CalendarToolsTests.swift` - Update expected tool count (5→9)

### Architecture Notes
- Uses `ReminderSnapshot` struct for Sendable data transfer across concurrency boundaries
- Reuses `EventStoreProvider.shared` EKEventStore instance
- Follows same patterns as calendar tools (ToolProtocol, validation, error handling)
- All tools include comprehensive logging via `os.Logger`

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing (40 reminders tests + updated calendar tests)
- [x] Build succeeds
