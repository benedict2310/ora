//
//  EventKitPermission.swift
//  Ora
//
//  Calendar and Reminders permission handling
//

import EventKit
import os

struct EventKitPermission: Sendable {

    private static let logger = Logger(subsystem: "com.ora.app", category: "EventKitPermission")

    /// Check calendar authorization status
    static func checkCalendarStatus() -> PermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        return mapStatus(status)
    }

    /// Check reminders authorization status
    static func checkRemindersStatus() -> PermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return mapStatus(status)
    }

    /// Request calendar permission
    static func requestCalendar() async -> PermissionStatus {
        let currentStatus = checkCalendarStatus()

        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        logger.info("Requesting calendar permission...")
        let store = EKEventStore()

        do {
            let granted = try await store.requestFullAccessToEvents()
            let newStatus: PermissionStatus = granted ? .authorized : .denied
            logger.info("Calendar permission: \(granted ? "granted" : "denied")")
            return newStatus
        } catch {
            logger.error("Calendar permission request failed: \(error.localizedDescription)")
            return .denied
        }
    }

    /// Request reminders permission
    static func requestReminders() async -> PermissionStatus {
        let currentStatus = checkRemindersStatus()

        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        logger.info("Requesting reminders permission...")
        let store = EKEventStore()

        do {
            let granted = try await store.requestFullAccessToReminders()
            let newStatus: PermissionStatus = granted ? .authorized : .denied
            logger.info("Reminders permission: \(granted ? "granted" : "denied")")
            return newStatus
        } catch {
            logger.error("Reminders permission request failed: \(error.localizedDescription)")
            return .denied
        }
    }

    private static func mapStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .authorized
        case .writeOnly: return .denied  // Ora needs read access
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }
}
