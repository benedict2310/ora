//
//  ToolHost.swift
//  Ora
//
//  Executes tools with confirmation and audit logging
//

import Foundation
import os

struct ToolExecutionRecord: Sendable {
    let result: ToolResult
    let auditEntryID: UUID
}

enum ToolExecutionError: LocalizedError, Sendable {
    case executionFailed(auditEntryID: UUID, message: String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(_, let message):
            return message
        }
    }

    var auditEntryID: UUID {
        switch self {
        case .executionFailed(let auditEntryID, _):
            return auditEntryID
        }
    }

    var message: String {
        switch self {
        case .executionFailed(_, let message):
            return message
        }
    }
}

/// Executes tools with proper guardrails
actor ToolHost {
    
    // MARK: - Singleton
    
    static let shared = ToolHost()
    
    // MARK: - Properties
    
    private let logger = Logger.ora(category: "ToolHost")
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Execute a tool call
    func execute(
        toolName: String,
        args: [String: JSONValue],
        confirmed: Bool,
        sessionID: UUID? = nil
    ) async throws -> ToolResult {
        let execution = try await self.executeWithAudit(
            toolName: toolName,
            args: args,
            confirmed: confirmed,
            sessionID: sessionID
        )
        return execution.result
    }

    /// Execute a tool call and return the resulting audit entry ID.
    func executeWithAudit(
        toolName: String,
        args: [String: JSONValue],
        confirmed: Bool,
        sessionID: UUID? = nil
    ) async throws -> ToolExecutionRecord {
        // Get tool
        guard let tool = await ToolRegistry.shared.tool(named: toolName) else {
            throw ToolHostError.toolNotFound(toolName)
        }
        
        // Check confirmation for mutations
        if tool.requiresConfirmation && !confirmed {
            throw ToolHostError.confirmationRequired(toolName)
        }
        
        // Validate arguments
        do {
            try tool.validate(args: args)
        } catch {
            throw ToolHostError.validationFailed(toolName, error.localizedDescription)
        }
        
        // Convert JSONValue args to raw [String: Any] for audit logging
        // This must be done here to get proper values, not type-tagged JSON
        let parameters = self.jsonValueToAnyDict(args)
        let action = tool.kind.rawValue
        
        // Serialize to JSON string (String is Sendable) for crossing actor boundary
        let parametersJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: parameters),
           let json = String(data: data, encoding: .utf8) {
            parametersJSON = json
        } else {
            parametersJSON = "{}"
        }
        
        // Record audit entry on MainActor
        let auditEntryID = await MainActor.run {
            // Decode parameters back from JSON string on MainActor
            let params: [String: Any]
            if let data = parametersJSON.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                params = decoded
            } else {
                params = [:]
            }
            
            let entry = AuditLogger.shared.recordToolCall(
                tool: toolName,
                action: action,
                parameters: params,
                userConfirmed: confirmed,
                sessionID: sessionID
            )
            return entry.id
        }
        
        // Execute
        do {
            let result = try await tool.execute(args: args)
            
            // Update audit with success
            let summary = result.humanSummary
            await MainActor.run {
                AuditLogger.shared.recordSuccess(auditEntryID, result: ["summary": summary])
            }
            
            logger.info("Tool executed: \(toolName)")
            return ToolExecutionRecord(result: result, auditEntryID: auditEntryID)
            
        } catch {
            // Update audit with failure
            let errorMessage = error.localizedDescription
            await MainActor.run {
                AuditLogger.shared.recordFailure(auditEntryID, error: errorMessage)
            }
            
            logger.error("Tool failed: \(toolName) - \(error.localizedDescription)")
            throw ToolExecutionError.executionFailed(auditEntryID: auditEntryID, message: errorMessage)
        }
    }
    
    // MARK: - Private
    
    /// Convert JSONValue dictionary to [String: Any] for serialization
    private func jsonValueToAnyDict(_ dict: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            result[key] = self.jsonValueToAny(value)
        }
        return result
    }
    
    /// Convert a single JSONValue to Any
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { self.jsonValueToAny($0) }
        case .object(let dict): return self.jsonValueToAnyDict(dict)
        }
    }
}

// MARK: - Errors

enum ToolHostError: LocalizedError, Equatable {
    case toolNotFound(String)
    case confirmationRequired(String)
    case validationFailed(String, String)
    
    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool '\(name)' not found."
        case .confirmationRequired(let name):
            return "Tool '\(name)' requires user confirmation."
        case .validationFailed(let name, let reason):
            return "Validation failed for '\(name)': \(reason)"
        }
    }
}
