//
//  AuditLogger.swift
//  Ora
//
//  Manages audit logging for tool executions and confirmations
//  Uses SwiftData via PersistenceManager for storage
//

import Foundation
import os

actor AuditLogger {

    // MARK: - Singleton

    static let shared = AuditLogger()

    // MARK: - Properties

    private let logger = Logger.ora(category: "AuditLogger")

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    @MainActor
    func recordToolCall(
        tool: String,
        action: String,
        category: AuditCategory = .toolExecution,
        parameters: [String: Any],
        userConfirmed: Bool,
        sessionID: UUID?
    ) -> AuditLogEntry {
        let entry = PersistenceManager.shared.recordToolExecution(
            toolName: tool,
            action: action,
            category: category,
            summary: "\(tool).\(action)",
            parameters: parameters,
            userConfirmed: userConfirmed,
            sessionID: sessionID
        )
        self.logger.info("Tool called: \(tool).\(action)")
        return entry.toAuditLogEntry()
    }

    @MainActor
    func recordSuccess(_ entryID: UUID, result: [String: Any]) {
        let entries = PersistenceManager.shared.recentAuditEntries(limit: 1000)
        if let entry = entries.first(where: { $0.id == entryID }) {
            PersistenceManager.shared.updateAuditEntry(entry, result: result, succeeded: true)
            self.logger.info("Tool succeeded: \(entry.toolName).\(entry.action)")
        }
    }

    @MainActor
    func recordFailure(
        _ entryID: UUID,
        error: String,
        result: [String: Any] = [:],
        categoryOverride: AuditCategory? = nil
    ) {
        let entries = PersistenceManager.shared.recentAuditEntries(limit: 1000)
        if let entry = entries.first(where: { $0.id == entryID }) {
            entry.category = (categoryOverride ?? .error).rawValue
            entry.setError(error)
            PersistenceManager.shared.updateAuditEntry(entry, result: result, succeeded: false)
            self.logger.error("Tool failed: \(entry.toolName).\(entry.action) - \(error)")
        }
    }

    @MainActor
    func recordConfirmation(action: String, confirmed: Bool, sessionID: UUID?) {
        _ = PersistenceManager.shared.recordToolExecution(
            toolName: "",
            action: action,
            category: .confirmation,
            summary: confirmed ? "Confirmed: \(action)" : "Cancelled: \(action)",
            parameters: [:],
            userConfirmed: confirmed,
            sessionID: sessionID
        )
        self.logger.debug("Confirmation: \(action) - \(confirmed)")
    }

    @MainActor
    func recordError(message: String, context: String?, sessionID: UUID?) {
        let entry = PersistenceManager.shared.recordToolExecution(
            toolName: "",
            action: "error",
            category: .error,
            summary: context ?? "Error",
            parameters: [:],
            userConfirmed: false,
            sessionID: sessionID
        )
        entry.setError(message)
        PersistenceManager.shared.updateAuditEntry(entry, result: [:], succeeded: false)
        self.logger.error("Error recorded: \(message)")
    }

    @MainActor
    func fetchEntries(limit: Int = 500) -> [AuditLogEntry] {
        let models = PersistenceManager.shared.recentAuditEntries(limit: limit)
        return models.map { $0.toAuditLogEntry() }
    }

    @MainActor
    func clearAll() {
        PersistenceManager.shared.clearAuditLog()
        self.logger.info("Audit log cleared")
    }

    @MainActor
    func exportTo(url: URL) {
        let entries = fetchEntries(limit: 10000)

        let exportEntries = Self.exportEntries(from: entries)

        do {
            let data = try JSONSerialization.data(withJSONObject: exportEntries, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            self.logger.info("Exported \(entries.count) audit log entries to \(url.path)")
        } catch {
            self.logger.error("Failed to export audit log: \(error.localizedDescription)")
        }
    }

    static func exportEntries(from entries: [AuditLogEntry]) -> [[String: Any]] {
        entries.map { exportEntry(for: $0) }
    }

    static func exportEntry(for entry: AuditLogEntry) -> [String: Any] {
        var dict: [String: Any] = [
            "id": entry.id.uuidString,
            "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
            "category": entry.category.rawValue,
            "summary": entry.summary,
            "success": entry.success,
            "userConfirmed": entry.userConfirmed
        ]
        if let toolName = entry.toolName { dict["toolName"] = toolName }
        if let result = entry.result { dict["result"] = result }
        if let error = entry.errorMessage { dict["error"] = error }
        if let sessionID = entry.sessionID { dict["sessionID"] = sessionID.uuidString }
        return dict
    }
}
