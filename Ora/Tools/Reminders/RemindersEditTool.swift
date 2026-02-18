//
//  RemindersEditTool.swift
//  Ora
//
//  Edit existing reminders (requires confirmation)
//

import Foundation
import os
@preconcurrency import EventKit

struct RemindersEditTool: Tool {
    let name = "reminders.edit"
    let kind: ToolKind = .mutate

    private static let logger = Logger.ora(category: "RemindersEditTool")

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Edit an existing reminder. Requires confirmation. Only provided fields are updated. Use reminders.list first to get the reminder_id.",
            parameters: [
                "reminder_id": ParameterSchema(type: "string", description: "Reminder identifier (from reminders.list)"),
                "title": ParameterSchema(type: "string", description: "New reminder title (optional)"),
                "due_date": ParameterSchema(type: "string", description: "New due date (ISO 8601, optional)", format: "date-time"),
                "notes": ParameterSchema(type: "string", description: "New notes (optional)"),
                "priority": ParameterSchema(type: "number", description: "New priority 0-9 (0=none, 1=high, 5=medium, 9=low)"),
                "list_name": ParameterSchema(type: "string", description: "Move to different list (optional)")
            ],
            requiredParameters: ["reminder_id"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let reminderID = args["reminder_id"]?.stringValue, !reminderID.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: reminder_id")
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
        Self.logger.info("RemindersEditTool.execute called")

        // Check reminders permission first
        try await RemindersStoreProvider.ensureRemindersAccess()
        Self.logger.info("Reminders access confirmed")

        let store = RemindersStoreProvider.shared

        guard let reminderID = args["reminder_id"]?.stringValue else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: reminder_id")
        }

        // Fetch the reminder by ID
        guard let calendarItem = store.calendarItem(withIdentifier: reminderID),
              let reminder = calendarItem as? EKReminder else {
            Self.logger.error("Reminder not found: \(reminderID)")
            throw RemindersToolError.reminderNotFound(reminderID)
        }

        let originalTitle = reminder.title ?? "Untitled"
        var changes: [String] = []

        // Apply updates only for provided fields
        if let title = args["title"]?.stringValue {
            reminder.title = title
            changes.append("title")
            Self.logger.info("Updated title to: \(title)")
        }

        if let dueDateStr = args["due_date"]?.stringValue,
           let dueDate = EventStoreProvider.parseDate(dueDateStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
            changes.append("due date")
            Self.logger.info("Updated due date to: \(dueDateStr)")
        }

        if let notes = args["notes"]?.stringValue {
            reminder.notes = notes
            changes.append("notes")
            Self.logger.info("Updated notes")
        }

        if let priority = args["priority"]?.numberValue {
            reminder.priority = Int(priority)
            changes.append("priority")
            Self.logger.info("Updated priority to: \(Int(priority))")
        }

        // Move to different list if specified
        if let listName = args["list_name"]?.stringValue {
            if let calendar = RemindersStoreProvider.findReminderListExact(named: listName) {
                reminder.calendar = calendar
                changes.append("list")
                Self.logger.info("Moved to list: \(calendar.title)")
            } else {
                Self.logger.warning("List '\(listName)' not found, skipping list change")
            }
        }

        do {
            try store.save(reminder, commit: true)
            Self.logger.info("Reminder saved successfully")
        } catch {
            Self.logger.error("Failed to save reminder: \(error.localizedDescription)")
            throw RemindersToolError.saveFailed(error.localizedDescription)
        }

        let changesText = changes.isEmpty ? "no fields" : changes.joined(separator: ", ")
        let summary = "Updated '\(originalTitle)': \(changesText)."

        return .success(
            .object([
                "reminder_id": .string(reminderID),
                "updated_fields": .array(changes.map { .string($0) })
            ]),
            summary: summary
        )
    }
}
