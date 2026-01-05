//
//  PreferencesViewTests.swift
//  OraTests
//
//  Tests for preferences SwiftUI views and helpers
//

import SwiftUI
import XCTest
@testable import Ora

@MainActor
final class PreferencesViewTests: XCTestCase {

    func test_permissionsPreferencesView_bodyBuilds() {
        let view = PermissionsPreferencesView()
        _ = view.body
    }

    func test_permissionRowView_bodyBuilds_forStatuses() {
        let statuses: [PermissionStatus] = [.authorized, .denied, .notDetermined, .restricted, .unknown]
        for status in statuses {
            let view = PermissionRowView(type: .microphone, status: status)
            _ = view.body
        }
    }

    func test_aboutPreferencesView_bodyBuilds() {
        let view = AboutPreferencesView()
        _ = view.body
    }

    func test_auditFilter_displayNames() {
        XCTAssertEqual(AuditFilter.all.displayName, "All")
        XCTAssertEqual(AuditFilter.tools.displayName, "Tools")
        XCTAssertEqual(AuditFilter.errors.displayName, "Errors")
        XCTAssertEqual(AuditFilter.confirmations.displayName, "Confirmations")
    }

    func test_auditLogView_filteredEntries_filtersByCategory() {
        let toolEntry = AuditLogEntry(category: .toolExecution, summary: "Tool")
        let confirmationEntry = AuditLogEntry(category: .confirmation, summary: "Confirm")
        let errorEntry = AuditLogEntry(category: .error, summary: "Error", success: false)
        let stateEntry = AuditLogEntry(category: .stateChange, summary: "State")
        let entries = [toolEntry, confirmationEntry, errorEntry, stateEntry]

        XCTAssertEqual(AuditLogView.filteredEntries(entries, filter: .all).count, 4)
        XCTAssertEqual(AuditLogView.filteredEntries(entries, filter: .tools).count, 1)
        XCTAssertEqual(AuditLogView.filteredEntries(entries, filter: .errors).count, 1)
        XCTAssertEqual(AuditLogView.filteredEntries(entries, filter: .confirmations).count, 1)
    }

    func test_auditLogView_formattedDate_usesExpectedPattern() {
        let date = Date(timeIntervalSince1970: 0)
        let formatted = AuditLogView.formattedDate(for: date)

        XCTAssertEqual(formatted.count, 10)
        XCTAssertEqual(formatted[formatted.index(formatted.startIndex, offsetBy: 4)], "-")
        XCTAssertEqual(formatted[formatted.index(formatted.startIndex, offsetBy: 7)], "-")
    }

    func test_auditLogEntryRow_bodyBuilds_forCategoriesAndStatuses() {
        let toolEntry = AuditLogEntry(category: .toolExecution, summary: "Tool", success: true)
        let confirmationEntry = AuditLogEntry(category: .confirmation, summary: "Confirm", success: true)
        let errorEntry = AuditLogEntry(category: .error, summary: "Error", errorMessage: "Boom", success: false)
        let stateEntry = AuditLogEntry(category: .stateChange, summary: "State", success: true)

        _ = AuditLogEntryRow(entry: toolEntry).body
        _ = AuditLogEntryRow(entry: confirmationEntry).body
        _ = AuditLogEntryRow(entry: errorEntry).body
        _ = AuditLogEntryRow(entry: stateEntry).body
    }

    func test_auditLogEntryRow_formattedTime_usesExpectedPattern() {
        let date = Date(timeIntervalSince1970: 0)
        let formatted = AuditLogEntryRow.formattedTime(for: date)

        XCTAssertEqual(formatted.count, 8)
        XCTAssertEqual(formatted[formatted.index(formatted.startIndex, offsetBy: 2)], ":")
        XCTAssertEqual(formatted[formatted.index(formatted.startIndex, offsetBy: 5)], ":")
    }

    func test_auditLogEntryRow_formatJSON_outputsString() {
        let jsonString = AuditLogEntryRow.formatJSON(["key": "value", "count": 2])
        XCTAssertTrue(jsonString.contains("key"))

        let fallback = AuditLogEntryRow.formatJSON(["date": Date()])
        XCTAssertTrue(fallback.contains("date"))
    }

    func test_appIcon_imageReturnsImage() {
        let image = AppIcon.image
        XCTAssertGreaterThanOrEqual(image.size.width, 0)
    }
}
