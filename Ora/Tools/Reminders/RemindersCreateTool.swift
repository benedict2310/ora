//
//  RemindersCreateTool.swift
//  Ora
//
//  Create new reminders (requires confirmation)
//

import Foundation
import os
@preconcurrency import EventKit

struct RemindersCreateTool: Tool {
    let name = "reminders.create"
    let kind: ToolKind = .mutate

    private static let logger = Logger(subsystem: "com.ora.app", category: "RemindersCreateTool")

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Create a new reminder. Requires confirmation.",
            parameters: [
                "title": ParameterSchema(type: "string", description: "Reminder title"),
                "due_date": ParameterSchema(type: "string", description: "Due date (ISO 8601, optional)", format: "date-time"),
                "list_name": ParameterSchema(type: "string", description: "Reminders list name (optional, uses default if omitted)"),
                "notes": ParameterSchema(type: "string", description: "Additional notes (optional)"),
                "priority": ParameterSchema(type: "number", description: "Priority 0-9 (0=none, 1=high, 5=medium, 9=low)")
            ],
            requiredParameters: ["title"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let title = args["title"]?.stringValue, !title.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: title")
        }

        // Validate date format if provided
        if let dueDateStr = args["due_date"]?.stringValue {
            guard EventStoreProvider.parseDate(dueDateStr) != nil else {
                throw RemindersToolError.invalidDateFormat(dueDateStr)
            }
        }

        // Validate priority if provided
        if let priority = args["priority"]?.numberValue {
            let intPriority = Int(priority)
            guard intPriority >= 0 && intPriority <= 9 else {
                throw ToolHostError.validationFailed(name, "Priority must be between 0 and 9")
            }
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        Self.logger.info("RemindersCreateTool.execute called with args: \(args.keys.joined(separator: ", "))")

        // Check reminders permission first
        try await RemindersStoreProvider.ensureRemindersAccess()
        Self.logger.info("Reminders access confirmed")

        let store = RemindersStoreProvider.shared

        guard let title = args["title"]?.stringValue else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: title")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = args["notes"]?.stringValue

        // Set due date if provided
        if let dueDateStr = args["due_date"]?.stringValue,
           let dueDate = EventStoreProvider.parseDate(dueDateStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
            Self.logger.info("Set due date: \(dueDateStr)")
        }

        // Set priority if provided
        if let priority = args["priority"]?.numberValue {
            reminder.priority = Int(priority)
            Self.logger.info("Set priority: \(Int(priority))")
        }

        // Find list by name or use default
        if let listName = args["list_name"]?.stringValue {
            if let calendar = RemindersStoreProvider.findReminderList(named: listName) {
                reminder.calendar = calendar
                Self.logger.info("Using specified list: \(calendar.title)")
            } else {
                Self.logger.warning("List '\(listName)' not found, using default")
            }
        }

        if reminder.calendar == nil {
            guard let defaultCalendar = store.defaultCalendarForNewReminders() else {
                Self.logger.error("No default reminders list available")
                throw RemindersToolError.noDefaultList
            }
            reminder.calendar = defaultCalendar
            Self.logger.info("Using default list: \(defaultCalendar.title)")
        }

        do {
            try store.save(reminder, commit: true)
            Self.logger.info("Reminder saved successfully with ID: \(reminder.calendarItemIdentifier)")
        } catch {
            Self.logger.error("Failed to save reminder: \(error.localizedDescription)")
            throw RemindersToolError.saveFailed(error.localizedDescription)
        }

        let summary = Self.summary(title: title, dueDate: args["due_date"]?.stringValue, list: reminder.calendar.title)

        return .success(
            .object([
                "reminder_id": .string(reminder.calendarItemIdentifier),
                "title": .string(title),
                "list": .string(reminder.calendar.title)
            ]),
            summary: summary
        )
    }

    // MARK: - Helpers (exposed for testing)

    static func summary(title: String, dueDate: String?, list: String) -> String {
        var summary = "Created reminder '\(title)'"
        if let dueDateStr = dueDate,
           let date = EventStoreProvider.parseDate(dueDateStr) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            summary += " due \(formatter.string(from: date))"
        }
        summary += " in '\(list)'."
        return summary
    }
}
