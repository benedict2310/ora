//
//  EventStoreProvider.swift
//  Ora
//
//  Shared EKEventStore provider for calendar tools
//

@preconcurrency import EventKit

/// Provides shared access to EKEventStore
enum EventStoreProvider {
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
}
