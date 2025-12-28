//
//  AuditLogger.swift
//  Ora
//
//  Manages audit logging for tool executions and confirmations
//

import Foundation
import os

actor AuditLogger {

    // MARK: - Singleton

    static let shared = AuditLogger()

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ora.app", category: "AuditLogger")
    private var entries: [AuditLogEntry] = []
    private let maxEntries = 10000

    // File-based storage
    private let storageURL: URL

    // MARK: - Initialization

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oraDir = appSupport.appendingPathComponent("Ora", isDirectory: true)
        self.storageURL = oraDir.appendingPathComponent("audit-log.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: oraDir, withIntermediateDirectories: true)

        // Load existing entries
        Task { await self.loadEntries() }
    }

    // MARK: - Public API

    func recordToolCall(
        tool: String,
        action: String,
        parameters: [String: Any],
        userConfirmed: Bool,
        sessionID: UUID?
    ) -> AuditLogEntry {
        let entry = AuditLogEntry(
            category: .toolExecution,
            summary: "\(tool).\(action)",
            toolName: tool,
            parameters: parameters,
            success: true,
            userConfirmed: userConfirmed,
            sessionID: sessionID
        )
        self.addEntry(entry)
        return entry
    }

    func recordSuccess(_ entryID: UUID, result: [String: Any]) {
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            var updated = entries[index]
            updated = AuditLogEntry(
                id: updated.id,
                timestamp: updated.timestamp,
                category: updated.category,
                summary: updated.summary,
                toolName: updated.toolName,
                parameters: updated.parameters,
                result: self.formatResult(result),
                errorMessage: nil,
                success: true,
                userConfirmed: updated.userConfirmed,
                sessionID: updated.sessionID
            )
            entries[index] = updated
            self.saveEntries()
        }
    }

    func recordFailure(_ entryID: UUID, error: String) {
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            var updated = entries[index]
            updated = AuditLogEntry(
                id: updated.id,
                timestamp: updated.timestamp,
                category: .error,
                summary: updated.summary,
                toolName: updated.toolName,
                parameters: updated.parameters,
                result: nil,
                errorMessage: error,
                success: false,
                userConfirmed: updated.userConfirmed,
                sessionID: updated.sessionID
            )
            entries[index] = updated
            self.saveEntries()
        }
    }

    func recordConfirmation(action: String, confirmed: Bool, sessionID: UUID?) {
        let entry = AuditLogEntry(
            category: .confirmation,
            summary: confirmed ? "Confirmed: \(action)" : "Cancelled: \(action)",
            success: true,
            userConfirmed: confirmed,
            sessionID: sessionID
        )
        self.addEntry(entry)
    }

    func recordError(message: String, context: String?, sessionID: UUID?) {
        let entry = AuditLogEntry(
            category: .error,
            summary: context ?? "Error",
            errorMessage: message,
            success: false,
            sessionID: sessionID
        )
        self.addEntry(entry)
    }

    func fetchEntries(limit: Int = 500) -> [AuditLogEntry] {
        Array(entries.suffix(limit).reversed())
    }

    func clearAll() {
        entries.removeAll()
        self.saveEntries()
        self.logger.info("Audit log cleared")
    }

    func exportTo(url: URL) {
        // Create a simplified exportable format
        let exportEntries = entries.map { entry -> [String: Any] in
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

        do {
            let data = try JSONSerialization.data(withJSONObject: exportEntries, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            self.logger.info("Exported \(self.entries.count) audit log entries to \(url.path)")
        } catch {
            self.logger.error("Failed to export audit log: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func addEntry(_ entry: AuditLogEntry) {
        entries.append(entry)

        // Trim if over limit
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        self.saveEntries()
        self.logger.debug("Audit: \(entry.summary)")
    }

    private func loadEntries() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([StoredEntry].self, from: data)
            entries = decoded.map { $0.toAuditLogEntry() }
            self.logger.debug("Loaded \(self.entries.count) audit log entries")
        } catch {
            self.logger.error("Failed to load audit log: \(error.localizedDescription)")
        }
    }

    private func saveEntries() {
        let storable = entries.map { StoredEntry(from: $0) }

        do {
            let data = try JSONEncoder().encode(storable)
            try data.write(to: storageURL)
        } catch {
            self.logger.error("Failed to save audit log: \(error.localizedDescription)")
        }
    }

    private func formatResult(_ result: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: result)
    }
}

// MARK: - Codable Storage Model

private struct StoredEntry: Codable {
    let id: UUID
    let timestamp: Date
    let category: String
    let summary: String
    let toolName: String?
    let parametersJSON: String?
    let result: String?
    let errorMessage: String?
    let success: Bool
    let userConfirmed: Bool
    let sessionID: UUID?

    init(from entry: AuditLogEntry) {
        self.id = entry.id
        self.timestamp = entry.timestamp
        self.category = entry.category.rawValue
        self.summary = entry.summary
        self.toolName = entry.toolName
        self.result = entry.result
        self.errorMessage = entry.errorMessage
        self.success = entry.success
        self.userConfirmed = entry.userConfirmed
        self.sessionID = entry.sessionID

        // Convert parameters to JSON string
        if let params = entry.parameters,
           let data = try? JSONSerialization.data(withJSONObject: params),
           let json = String(data: data, encoding: .utf8) {
            self.parametersJSON = json
        } else {
            self.parametersJSON = nil
        }
    }

    func toAuditLogEntry() -> AuditLogEntry {
        var params: [String: Any]?
        if let json = parametersJSON,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            params = dict
        }

        return AuditLogEntry(
            id: id,
            timestamp: timestamp,
            category: AuditCategory(rawValue: category) ?? .stateChange,
            summary: summary,
            toolName: toolName,
            parameters: params,
            result: result,
            errorMessage: errorMessage,
            success: success,
            userConfirmed: userConfirmed,
            sessionID: sessionID
        )
    }
}
