//
//  RemindersListTool.swift
//  Ora
//
//  List reminders with optional filters
//

import Foundation
import os
@preconcurrency import EventKit

/// Sendable snapshot of reminder data for crossing concurrency boundaries
struct ReminderSnapshot: Sendable {
    let id: String
    let title: String
    let dueDate: Date?
    let isCompleted: Bool
    let listName: String
    let priority: Int
    let notes: String?
}

struct RemindersListTool: Tool {
    let name = "reminders.list"
    let kind: ToolKind = .read

    private static let logger = Logger.ora(category: "RemindersListTool")

    var schema: ToolSchema {
        ToolSchema(
            name: name,
            description: "List reminders, optionally filtered by list or completion status",
            parameters: [
                "list_name": ParameterSchema(type: "string", description: "Filter by list name (optional)"),
                "include_completed": ParameterSchema(type: "boolean", description: "Include completed reminders (default: false)")
            ],
            requiredParameters: [],
            requiresConfirmation: false
        )
    }

    func validate(args: [String: JSONValue]) throws {
        // No required parameters - all are optional
    }

    func execute(args: [String: JSONValue]) async throws -> ToolResult {
        Self.logger.info("RemindersListTool.execute called")

        // Check reminders permission first
        try await RemindersStoreProvider.ensureRemindersAccess()
        Self.logger.info("Reminders access confirmed")

        let store = RemindersStoreProvider.shared
        let includeCompleted = args["include_completed"]?.boolValue ?? false
        let listNameFilter = args["list_name"]?.stringValue

        // Determine which calendars to search
        let calendars: [EKCalendar]
        if let listName = listNameFilter {
            if let calendar = RemindersStoreProvider.findReminderList(named: listName) {
                calendars = [calendar]
            } else {
                // No matching list found
                return .success(.array([]), summary: "No reminders list found matching '\(listName)'.")
            }
        } else {
            calendars = RemindersStoreProvider.allReminderLists()
        }

        let predicate = store.predicateForReminders(in: calendars)

        // Fetch reminders and convert to Sendable snapshots within the callback
        let snapshots = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ReminderSnapshot], Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                let converted = (reminders ?? []).map { reminder in
                    ReminderSnapshot(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "",
                        dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        isCompleted: reminder.isCompleted,
                        listName: reminder.calendar.title,
                        priority: reminder.priority,
                        notes: reminder.notes
                    )
                }
                continuation.resume(returning: converted)
            }
        }

        Self.logger.info("Fetched \(snapshots.count) reminders from store")

        // Filter by completion status
        var filtered = snapshots
        if !includeCompleted {
            filtered = snapshots.filter { !$0.isCompleted }
        }

        Self.logger.info("After filtering: \(filtered.count) reminders")

        // Convert to JSON, limit to 20 results
        let reminderData: [JSONValue] = filtered.prefix(20).map { snapshot in
            Self.snapshotToJSON(snapshot)
        }

        let summary = Self.summary(for: filtered.count, listName: listNameFilter, includeCompleted: includeCompleted)

        return .success(.array(reminderData), summary: summary)
    }

    // MARK: - Helpers (exposed for testing)

    static func snapshotToJSON(_ snapshot: ReminderSnapshot) -> JSONValue {
        let dueDate: JSONValue
        if let date = snapshot.dueDate {
            dueDate = .string(EventStoreProvider.formatDate(date))
        } else {
            dueDate = .null
        }

        return .object([
            "id": .string(snapshot.id),
            "title": .string(snapshot.title),
            "due_date": dueDate,
            "completed": .bool(snapshot.isCompleted),
            "list": .string(snapshot.listName),
            "priority": .number(Double(snapshot.priority)),
            "notes": snapshot.notes.map { .string($0) } ?? .null
        ])
    }

    static func summary(for count: Int, listName: String?, includeCompleted: Bool) -> String {
        let listClause = listName.map { " in '\($0)'" } ?? ""
        let completedClause = includeCompleted ? " (including completed)" : ""

        if count == 0 {
            return "No reminders found\(listClause)\(completedClause)."
        } else if count == 1 {
            return "Found 1 reminder\(listClause)\(completedClause)."
        } else {
            return "Found \(count) reminders\(listClause)\(completedClause)."
        }
    }
}
