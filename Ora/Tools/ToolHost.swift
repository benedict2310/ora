//
//  ToolHost.swift
//  Ora
//
//  Executes tools with confirmation and audit logging
//

import Foundation
import os

/// Executes tools with proper guardrails
actor ToolHost {
    
    // MARK: - Singleton
    
    static let shared = ToolHost()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "ToolHost")
    
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
        
        let parameters = argsToDict(args)
        
        // Record audit entry
        let auditEntry = await MainActor.run {
            AuditLogger.shared.recordToolCall(
                tool: toolName,
                action: tool.kind.rawValue,
                parameters: parameters,
                userConfirmed: confirmed,
                sessionID: sessionID
            )
        }
        
        // Execute
        do {
            let result = try await tool.execute(args: args)
            
            // Update audit
            await MainActor.run {
                AuditLogger.shared.recordSuccess(auditEntry.id, result: ["summary": result.humanSummary])
            }
            
            logger.info("Tool executed: \(toolName)")
            return result
            
        } catch {
            // Update audit with failure
            await MainActor.run {
                AuditLogger.shared.recordFailure(auditEntry.id, error: error.localizedDescription)
            }
            
            logger.error("Tool failed: \(toolName) - \(error.localizedDescription)")
            throw error
        }
    }
    
    private func argsToDict(_ args: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in args {
            result[key] = jsonValueToAny(value)
        }
        return result
    }
    
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
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
