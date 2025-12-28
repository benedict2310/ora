//
//  ContactsPermission.swift
//  Ora
//
//  Contacts permission handling
//

import Contacts
import os

struct ContactsPermission: Sendable {

    private static let logger = Logger(subsystem: "com.ora.app", category: "ContactsPermission")

    /// Check current authorization status
    static func checkStatus() -> PermissionStatus {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return mapStatus(status)
    }

    /// Request contacts permission
    static func request() async -> PermissionStatus {
        let currentStatus = checkStatus()

        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        logger.info("Requesting contacts permission...")
        let store = CNContactStore()

        do {
            let granted = try await store.requestAccess(for: .contacts)
            let newStatus: PermissionStatus = granted ? .authorized : .denied
            logger.info("Contacts permission: \(granted ? "granted" : "denied")")
            return newStatus
        } catch {
            logger.error("Contacts permission request failed: \(error.localizedDescription)")
            return .denied
        }
    }

    private static func mapStatus(_ status: CNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .limited: return .authorized  // Limited access is still usable
        @unknown default: return .unknown
        }
    }
}
