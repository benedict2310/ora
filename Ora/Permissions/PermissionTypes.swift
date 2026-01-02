//
//  PermissionTypes.swift
//  Ora
//
//  Permission type definitions for system permission management
//

import AppKit
import Foundation

// MARK: - Permission Type

enum PermissionType: String, CaseIterable, Sendable {
    case microphone
    case calendar
    case reminders
    case contacts

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            return "Required for voice input and speech recognition"
        case .calendar:
            return "Allows querying and creating calendar events"
        case .reminders:
            return "Allows creating and managing reminders"
        case .contacts:
            return "Allows searching contacts by name"
        }
    }

    var isRequired: Bool {
        switch self {
        case .microphone:
            return true
        case .calendar, .reminders, .contacts:
            return false
        }
    }

    var settingsURLString: String {
        switch self {
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .calendar:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .reminders:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .contacts:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }
    }
}

// MARK: - Permission Status

enum PermissionStatus: String, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unknown

    var isGranted: Bool {
        self == .authorized
    }

    var canRequest: Bool {
        self == .notDetermined
    }
}

// MARK: - Permissions Client Protocol

/// Protocol for checking and requesting permissions (enables testing via dependency injection)
protocol PermissionsClient: Sendable {
    func checkStatus(for type: PermissionType) -> PermissionStatus
    func request(_ type: PermissionType) async -> PermissionStatus
    @MainActor func openSettings(for type: PermissionType)
}

// MARK: - Permissions State

struct PermissionsState: Equatable, Sendable {
    var microphone: PermissionStatus = .unknown
    var calendar: PermissionStatus = .unknown
    var reminders: PermissionStatus = .unknown
    var contacts: PermissionStatus = .unknown

    subscript(type: PermissionType) -> PermissionStatus {
        get {
            switch type {
            case .microphone: return microphone
            case .calendar: return calendar
            case .reminders: return reminders
            case .contacts: return contacts
            }
        }
        set {
            switch type {
            case .microphone: microphone = newValue
            case .calendar: calendar = newValue
            case .reminders: reminders = newValue
            case .contacts: contacts = newValue
            }
        }
    }

    var requiredPermissionsGranted: Bool {
        microphone.isGranted
    }

    var allPermissionsGranted: Bool {
        PermissionType.allCases.allSatisfy { self[$0].isGranted }
    }
}

// MARK: - Live Permissions Client

/// Production implementation that calls real system APIs
struct LivePermissionsClient: PermissionsClient {
    func checkStatus(for type: PermissionType) -> PermissionStatus {
        switch type {
        case .microphone:
            return MicrophonePermission.checkStatus()
        case .calendar:
            return EventKitPermission.checkCalendarStatus()
        case .reminders:
            return EventKitPermission.checkRemindersStatus()
        case .contacts:
            return ContactsPermission.checkStatus()
        }
    }

    func request(_ type: PermissionType) async -> PermissionStatus {
        switch type {
        case .microphone:
            return await MicrophonePermission.request()
        case .calendar:
            return await EventKitPermission.requestCalendar()
        case .reminders:
            return await EventKitPermission.requestReminders()
        case .contacts:
            return await ContactsPermission.request()
        }
    }

    @MainActor
    func openSettings(for type: PermissionType) {
        if let url = URL(string: type.settingsURLString) {
            NSWorkspace.shared.open(url)
        }
    }
}

