//
//  AuditLogEntry.swift
//  Ora
//
//  Audit log entry model for tracking tool executions
//

import Foundation

// MARK: - Audit Log Entry

struct AuditLogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let category: AuditCategory
    let summary: String
    let toolName: String?
    let parametersJSON: String?  // Store as JSON string for Sendable compliance
    let result: String?
    let errorMessage: String?
    let success: Bool
    let userConfirmed: Bool
    let sessionID: UUID?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: AuditCategory,
        summary: String,
        toolName: String? = nil,
        parameters: [String: Any]? = nil,
        result: String? = nil,
        errorMessage: String? = nil,
        success: Bool = true,
        userConfirmed: Bool = false,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.summary = summary
        self.toolName = toolName
        self.result = result
        self.errorMessage = errorMessage
        self.success = success
        self.userConfirmed = userConfirmed
        self.sessionID = sessionID

        // Convert parameters to JSON string
        if let params = parameters,
           let data = try? JSONSerialization.data(withJSONObject: params),
           let json = String(data: data, encoding: .utf8) {
            self.parametersJSON = json
        } else {
            self.parametersJSON = nil
        }
    }

    /// Get parameters as dictionary (for display purposes)
    var parameters: [String: Any]? {
        guard let json = parametersJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }
}

// MARK: - Audit Category

enum AuditCategory: String, Sendable {
    case toolExecution
    case confirmation
    case error
    case stateChange
}

// MARK: - Sendable Conformance

extension AuditLogEntry: Sendable {}
