//
//  AuditLoggerTests.swift
//  OraTests
//
//  Tests for audit logging helpers and models
//

import XCTest
@testable import Ora

final class AuditLoggerExportTests: XCTestCase {

    func test_exportEntry_includesOptionalFields() {
        let entryID = UUID()
        let sessionID = UUID()
        let timestamp = Date(timeIntervalSince1970: 0)
        let entry = AuditLogEntry(
            id: entryID,
            timestamp: timestamp,
            category: .toolExecution,
            summary: "calendar.create",
            toolName: "calendar",
            parameters: ["title": "Standup"],
            result: "ok",
            errorMessage: "failed",
            success: false,
            userConfirmed: true,
            sessionID: sessionID
        )

        let exported = AuditLogger.exportEntry(for: entry)

        XCTAssertEqual(exported["id"] as? String, entryID.uuidString)
        XCTAssertEqual(exported["timestamp"] as? String, ISO8601DateFormatter().string(from: timestamp))
        XCTAssertEqual(exported["category"] as? String, AuditCategory.toolExecution.rawValue)
        XCTAssertEqual(exported["summary"] as? String, "calendar.create")
        XCTAssertEqual(exported["success"] as? Bool, false)
        XCTAssertEqual(exported["userConfirmed"] as? Bool, true)
        XCTAssertEqual(exported["toolName"] as? String, "calendar")
        XCTAssertEqual(exported["result"] as? String, "ok")
        XCTAssertEqual(exported["error"] as? String, "failed")
        XCTAssertEqual(exported["sessionID"] as? String, sessionID.uuidString)
    }

    func test_exportEntry_omitsOptionalFields() {
        let entry = AuditLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 0),
            category: .confirmation,
            summary: "Confirmed: action",
            toolName: nil,
            parameters: nil,
            result: nil,
            errorMessage: nil,
            success: true,
            userConfirmed: true,
            sessionID: nil
        )

        let exported = AuditLogger.exportEntry(for: entry)

        XCTAssertNil(exported["toolName"])
        XCTAssertNil(exported["result"])
        XCTAssertNil(exported["error"])
        XCTAssertNil(exported["sessionID"])
    }

    func test_exportEntries_mapsAllEntries() {
        let entries = [
            AuditLogEntry(category: .toolExecution, summary: "One"),
            AuditLogEntry(category: .error, summary: "Two")
        ]

        let exported = AuditLogger.exportEntries(from: entries)
        XCTAssertEqual(exported.count, 2)
    }
}

final class AuditLogEntryTests: XCTestCase {

    func test_parameters_roundTrip() {
        let entry = AuditLogEntry(
            category: .toolExecution,
            summary: "Test",
            parameters: ["title": "Standup", "count": 2]
        )

        let params = entry.parameters
        XCTAssertEqual(params?["title"] as? String, "Standup")
        XCTAssertEqual(params?["count"] as? Int, 2)
    }

    func test_parameters_nil_returnsNil() {
        let entry = AuditLogEntry(
            category: .toolExecution,
            summary: "Test",
            parameters: nil
        )

        XCTAssertNil(entry.parameters)
    }
}

final class AuditLogEntryModelTests: XCTestCase {

    func test_setParameters_roundTrip() {
        let model = AuditLogEntryModel(
            toolName: "calendar",
            action: "create",
            category: AuditCategory.toolExecution.rawValue,
            summary: "Create"
        )

        model.setParameters(["title": "Standup", "count": 2])
        let params = model.parameters
        XCTAssertEqual(params?["title"] as? String, "Standup")
        XCTAssertEqual(params?["count"] as? Int, 2)
    }

    func test_setResult_setsResultAndSuccess() {
        let model = AuditLogEntryModel(
            toolName: "calendar",
            action: "create",
            category: AuditCategory.toolExecution.rawValue,
            summary: "Create"
        )

        model.setResult(["b": 2, "a": 1], succeeded: true)
        XCTAssertEqual(model.succeeded, true)
        XCTAssertNotNil(model.result)
    }

    func test_setError_setsErrorMessageAndFails() {
        let model = AuditLogEntryModel(
            toolName: "calendar",
            action: "create",
            category: AuditCategory.toolExecution.rawValue,
            summary: "Create"
        )

        model.setError("Boom")
        XCTAssertEqual(model.errorMessage, "Boom")
        XCTAssertEqual(model.succeeded, false)
    }

    func test_toAuditLogEntry_mapsToolNameAndCategory() {
        let model = AuditLogEntryModel(
            toolName: "",
            action: "",
            category: "invalid-category",
            summary: "Summary",
            userConfirmed: true,
            sessionID: nil
        )

        let entry = model.toAuditLogEntry()
        XCTAssertNil(entry.toolName)
        XCTAssertEqual(entry.category, .stateChange)
        XCTAssertEqual(entry.userConfirmed, true)
    }
}
