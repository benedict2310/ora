//
//  AuditLogEntryModel.swift
//  Ora
//
//  SwiftData model for audit log entries
//

import Foundation
import SwiftData

@Model
final class AuditLogEntryModel {

    // MARK: - Properties

    /// Unique identifier
    @Attribute(.unique) var id: UUID

    /// When this action occurred
    var timestamp: Date

    /// Tool that was executed
    var toolName: String

    /// Action type (create, delete, query, etc.)
    var action: String

    /// Category of the entry
    var category: String

    /// Summary description
    var summary: String

    /// Parameters passed to the tool (JSON)
    var parametersData: Data?

    /// Result of the execution (JSON string)
    var result: String?

    /// Whether the user confirmed this action
    var userConfirmed: Bool

    /// Whether the action succeeded
    var succeeded: Bool

    /// Error message if failed
    var errorMessage: String?

    /// Related session ID
    var sessionID: UUID?

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        toolName: String,
        action: String,
        category: String,
        summary: String,
        userConfirmed: Bool = false,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.toolName = toolName
        self.action = action
        self.category = category
        self.summary = summary
        self.userConfirmed = userConfirmed
        self.succeeded = false
        self.sessionID = sessionID
    }

    // MARK: - Convenience Initializer

    convenience init(from entry: AuditLogEntry) {
        self.init(
            id: entry.id,
            timestamp: entry.timestamp,
            toolName: entry.toolName ?? "",
            action: "",
            category: entry.category.rawValue,
            summary: entry.summary,
            userConfirmed: entry.userConfirmed,
            sessionID: entry.sessionID
        )
        self.result = entry.result
        self.errorMessage = entry.errorMessage
        self.succeeded = entry.success

        // Convert parameters to Data
        if let params = entry.parameters,
           let data = try? JSONSerialization.data(withJSONObject: params) {
            self.parametersData = data
        }
    }

    // MARK: - Computed Properties

    var parameters: [String: Any]? {
        guard let data = parametersData else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Setters

    func setParameters(_ params: [String: Any]) {
        parametersData = try? JSONSerialization.data(withJSONObject: params)
    }

    func setResult(_ resultDict: [String: Any], succeeded: Bool) {
        if let data = try? JSONSerialization.data(withJSONObject: resultDict, options: .sortedKeys),
           let string = String(data: data, encoding: .utf8) {
            self.result = string
        }
        self.succeeded = succeeded
    }

    func setError(_ message: String) {
        self.errorMessage = message
        self.succeeded = false
    }

    // MARK: - Conversion

    func toAuditLogEntry() -> AuditLogEntry {
        let normalizedCategory = self.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCategory = AuditCategory(rawValue: normalizedCategory)
            ?? AuditCategory.allCases.first(where: {
                $0.rawValue.caseInsensitiveCompare(normalizedCategory) == .orderedSame
            })
            ?? .stateChange

        return AuditLogEntry(
            id: id,
            timestamp: timestamp,
            category: resolvedCategory,
            summary: summary,
            toolName: toolName.isEmpty ? nil : toolName,
            parameters: parameters,
            result: result,
            errorMessage: errorMessage,
            success: succeeded,
            userConfirmed: userConfirmed,
            sessionID: sessionID
        )
    }
}
