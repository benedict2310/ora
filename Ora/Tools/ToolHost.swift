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
        
        // Convert args to JSON data for sending across actor boundary (Data is Sendable)
        let parametersData = try JSONEncoder().encode(args)
        let action = tool.kind.rawValue
        
        // Record audit entry on MainActor
        let auditEntryID = await MainActor.run {
            // Decode parameters back on MainActor
            let parameters: [String: Any]
            if let decoded = try? JSONSerialization.jsonObject(with: parametersData) as? [String: Any] {
                parameters = decoded
            } else {
                parameters = [:]
            }
            
            let entry = AuditLogger.shared.recordToolCall(
                tool: toolName,
                action: action,
                parameters: parameters,
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
            return result
            
        } catch {
            // Update audit with failure
            let errorMessage = error.localizedDescription
            await MainActor.run {
                AuditLogger.shared.recordFailure(auditEntryID, error: errorMessage)
            }
            
            logger.error("Tool failed: \(toolName) - \(error.localizedDescription)")
            throw error
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
