//
//  RemindersStoreProvider.swift
//  Ora
//
//  Shared EKEventStore provider for reminders tools
//

@preconcurrency import EventKit
import os

/// Provides shared access to EKEventStore for reminders
enum RemindersStoreProvider {

    private static let logger = Logger.ora(category: "RemindersStoreProvider")
    static let fuzzyThreshold: Double = 0.85

    enum RemindersAccessAction: Equatable {
        case authorized
        case requestAccess
        case denied
    }

    /// Shared event store instance (reuses EventStoreProvider's store)
    /// Note: EKEventStore is thread-safe and handles both events and reminders
    static var shared: EKEventStore {
        EventStoreProvider.shared
    }

    /// Check if reminders access is authorized, and request if not determined
    /// - Throws: RemindersToolError.permissionDenied if access is denied
    static func ensureRemindersAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)

        switch authorizationAction(for: status) {
        case .authorized:
            logger.debug("Reminders access already authorized")
            return
        case .requestAccess:
            logger.info("Requesting reminders access...")
            do {
                await PermissionPromptTracker.shared.beginPrompt(for: .reminders)
                let granted = try await shared.requestFullAccessToReminders()
                await PermissionPromptTracker.shared.endPrompt(for: .reminders)
                if granted {
                    logger.info("Reminders access granted")
                    return
                } else {
                    logger.warning("Reminders access denied by user")
                    throw RemindersToolError.permissionDenied
                }
            } catch {
                await PermissionPromptTracker.shared.endPrompt(for: .reminders)
                logger.error("Reminders access request failed: \(error.localizedDescription)")
                throw RemindersToolError.permissionDenied
            }
        case .denied:
            logger.warning("Reminders access denied (status: \(String(describing: status)))")
            throw RemindersToolError.permissionDenied
        }
    }

    static func authorizationAction(for status: EKAuthorizationStatus) -> RemindersAccessAction {
        switch status {
        case .fullAccess, .authorized:
            return .authorized
        case .notDetermined:
            return .requestAccess
        case .denied, .writeOnly, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// Find a reminder list by name with fuzzy fallback.
    static func findReminderList(named name: String) -> EKCalendar? {
        let calendars = shared.calendars(for: .reminder)
        return findReminderList(named: name, in: calendars, allowFuzzy: true)
    }

    /// Find a reminder list by name using exact case-insensitive matching only.
    static func findReminderListExact(named name: String) -> EKCalendar? {
        let calendars = shared.calendars(for: .reminder)
        return findReminderList(named: name, in: calendars, allowFuzzy: false)
    }

    /// Find a reminder list by name in a given set of calendars.
    static func findReminderList(
        named name: String,
        in calendars: [EKCalendar],
        allowFuzzy: Bool
    ) -> EKCalendar? {
        let loweredName = name.lowercased()
        if let exactMatch = calendars.first(where: { $0.title.lowercased() == loweredName }) {
            return exactMatch
        }
        guard allowFuzzy else { return nil }

        let scored = calendars
            .map { calendar in
                (calendar: calendar, score: StringSimilarity.jaroWinkler(name, calendar.title))
            }
            .filter { $0.score >= fuzzyThreshold }
            .sorted { lhs, rhs in
                let delta = lhs.score - rhs.score
                if abs(delta) < 0.0001 {
                    return lhs.calendar.title.lowercased() < rhs.calendar.title.lowercased()
                }
                return lhs.score > rhs.score
            }

        return scored.first?.calendar
    }

    /// Get all reminder lists
    static func allReminderLists() -> [EKCalendar] {
        shared.calendars(for: .reminder)
    }
}
