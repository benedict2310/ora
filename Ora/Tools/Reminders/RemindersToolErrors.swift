//
//  RemindersToolErrors.swift
//  Ora
//
//  Error types for reminders tools
//

import Foundation

enum RemindersToolError: LocalizedError {
    case reminderNotFound(String)
    case invalidDateFormat(String)
    case noDefaultList
    case permissionDenied
    case saveFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .reminderNotFound(let id):
            return "Reminder not found: \(id)"
        case .invalidDateFormat(let value):
            return "Invalid date format: \(value). Use ISO 8601 format."
        case .noDefaultList:
            return "No default reminders list available."
        case .permissionDenied:
            return "Reminders access denied. Please grant permission in System Settings."
        case .saveFailed(let reason):
            return "Failed to save reminder: \(reason)"
        case .deleteFailed(let reason):
            return "Failed to delete reminder: \(reason)"
        }
    }
}
