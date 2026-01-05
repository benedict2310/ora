//
//  EventStoreProvider.swift
//  Ora
//
//  Shared EKEventStore provider for calendar tools
//

@preconcurrency import EventKit
import os

/// Provides shared access to EKEventStore
enum EventStoreProvider {
    
    private static let logger = Logger(subsystem: "com.ora.app", category: "EventStoreProvider")
    
    /// Shared event store instance
    /// Note: EKEventStore is thread-safe and meant to be reused
    nonisolated(unsafe) static let shared = EKEventStore()
    
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
    
    /// Check if calendar access is authorized, and request if not determined
    /// - Throws: CalendarToolError.permissionDenied if access is denied
    static func ensureCalendarAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        
        switch status {
        case .fullAccess, .authorized:
            // Already authorized
            logger.debug("Calendar access already authorized")
            return
            
        case .notDetermined:
            // Request access
            logger.info("Requesting calendar access...")
            do {
                await PermissionPromptTracker.shared.beginPrompt(for: .calendar)
                let granted = try await shared.requestFullAccessToEvents()
                await PermissionPromptTracker.shared.endPrompt(for: .calendar)
                if granted {
                    logger.info("Calendar access granted")
                    return
                } else {
                    logger.warning("Calendar access denied by user")
                    throw CalendarToolError.permissionDenied
                }
            } catch {
                await PermissionPromptTracker.shared.endPrompt(for: .calendar)
                logger.error("Calendar access request failed: \(error.localizedDescription)")
                throw CalendarToolError.permissionDenied
            }
            
        case .denied, .writeOnly:
            logger.warning("Calendar access denied (status: \(String(describing: status)))")
            throw CalendarToolError.permissionDenied
            
        case .restricted:
            logger.warning("Calendar access restricted")
            throw CalendarToolError.permissionDenied
            
        @unknown default:
            logger.warning("Unknown calendar authorization status")
            throw CalendarToolError.permissionDenied
        }
    }
}
