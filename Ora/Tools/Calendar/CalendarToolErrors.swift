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
