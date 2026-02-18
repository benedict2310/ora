//
//  RemindersCompleteTool.swift
//  Ora
//
//  Mark reminders as complete (requires confirmation)
//

import Foundation
import os
@preconcurrency import EventKit

struct RemindersCompleteTool: Tool {
    let name = "reminders.complete"
    let kind: ToolKind = .mutate

    private static let logger = Logger.ora(category: "RemindersCompleteTool")

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "Mark a reminder as complete. Requires confirmation. Use reminders.list first to get the reminder_id.",
            parameters: [
                "reminder_id": ParameterSchema(type: "string", description: "Reminder identifier (from reminders.list)")
            ],
            requiredParameters: ["reminder_id"],
            requiresConfirmation: true
        )
    }

    func validate(args: [String: JSONValue]) throws {
        guard let reminderID = args["reminder_id"]?.stringValue, !reminderID.isEmpty else {
            throw ToolHostError.validationFailed(name, "Missing required parameter: reminder_id")
        }
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        Self.logger.info("RemindersCompleteTool.execute called")

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

        let title = reminder.title ?? "Untitled"

        // Check if already completed
        if reminder.isCompleted {
            Self.logger.info("Reminder '\(title)' is already completed")
            return .success(
                .object([
                    "reminder_id": .string(reminderID),
                    "title": .string(title),
                    "already_completed": .bool(true)
                ]),
                summary: "Reminder '\(title)' was already completed."
            )
        }

        // Mark as complete
        reminder.isCompleted = true
        reminder.completionDate = Date()

        do {
            try store.save(reminder, commit: true)
            Self.logger.info("Reminder '\(title)' marked as complete")
        } catch {
            Self.logger.error("Failed to save reminder: \(error.localizedDescription)")
            throw RemindersToolError.saveFailed(error.localizedDescription)
        }

        return .success(
            .object([
                "reminder_id": .string(reminderID),
                "title": .string(title),
                "completed": .bool(true)
            ]),
            summary: "Marked '\(title)' as complete."
        )
    }
}
