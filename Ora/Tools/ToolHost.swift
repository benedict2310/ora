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

    private struct PendingAuthorization: Sendable {
        enum Mode: String, Sendable {
            case automatic
            case interactive
        }

        let tool: any Tool
        let ticket: ToolExecutionTicket
        let sessionID: UUID?
        let auditCategory: AuditCategory
        let action: String
        let auditMetadata: [String: String]
        let auditArgs: [String: JSONValue]
        let context: [String: JSONValue]
        var receipt: ToolAuthorizationReceipt?
        var mode: Mode?
    }
    
    // MARK: - Singleton
    
    static let shared = ToolHost()
    
    // MARK: - Properties
    
    private let logger = Logger.ora(category: "ToolHost")
    private var pendingAuthorizations: [UUID: PendingAuthorization] = [:]
    
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
        let preflight = try await self.preflight(
            toolName: toolName,
            args: args,
            sessionID: sessionID
        )

        switch preflight.disposition {
        case .allowed(let receipt):
            return try await self.executeAuthorized(ticket: preflight.ticket, receipt: receipt)

        case .requiresUser:
            guard confirmed else {
                self.cancel(ticketID: preflight.ticket.id)
                throw ToolHostError.confirmationRequired(toolName)
            }

            let receipt = try await self.authorize(
                ticketID: preflight.ticket.id,
                decision: .approveOnce
            )
            return try await self.executeAuthorized(ticket: preflight.ticket, receipt: receipt)
        }
    }

    func preflight(
        toolName: String,
        args: [String: JSONValue],
        sessionID: UUID? = nil
    ) async throws -> ToolPreflightResult {
        guard let tool = await ToolRegistry.shared.tool(named: toolName) else {
            throw ToolHostError.toolNotFound(toolName)
        }

        do {
            try tool.validate(args: args)
        } catch let error as ToolHostError {
            throw error
        } catch {
            throw ToolHostError.validationFailed(toolName, error.localizedDescription)
        }

        let plan = try await tool.authorizationPlan(args: args)
        let ticket = ToolExecutionTicket(toolName: toolName, args: args)
        let pending = PendingAuthorization(
            tool: tool,
            ticket: ticket,
            sessionID: sessionID,
            auditCategory: self.auditCategory(for: toolName),
            action: tool.kind.rawValue,
            auditMetadata: plan.auditMetadata,
            auditArgs: tool.auditParameters(args: args),
            context: plan.context,
            receipt: nil,
            mode: nil
        )
        self.pendingAuthorizations[ticket.id] = pending

        switch plan.requirement {
        case .none:
            let receipt = ToolAuthorizationReceipt(
                ticketID: ticket.id,
                toolName: toolName,
                decision: .approveOnce
            )
            var authorizedPending = pending
            authorizedPending.receipt = receipt
            authorizedPending.mode = .automatic
            self.pendingAuthorizations[ticket.id] = authorizedPending
            return ToolPreflightResult(ticket: ticket, disposition: .allowed(receipt: receipt))

        case .userConfirmation(let prompt):
            return ToolPreflightResult(ticket: ticket, disposition: .requiresUser(prompt: prompt))
        }
    }

    func authorize(
        ticketID: UUID,
        decision: ToolAuthorizationDecision
    ) async throws -> ToolAuthorizationReceipt {
        guard var pending = self.pendingAuthorizations[ticketID] else {
            throw ToolHostError.invalidAuthorizationTicket
        }

        if decision == .deny {
            self.pendingAuthorizations.removeValue(forKey: ticketID)
            throw ToolHostError.authorizationDenied("Authorization was denied.")
        }

        guard pending.receipt == nil else {
            throw ToolHostError.invalidAuthorizationReceipt
        }

        try await pending.tool.handleAuthorizationDecision(
            args: pending.ticket.args,
            context: pending.context,
            decision: decision
        )

        let receipt = ToolAuthorizationReceipt(
            ticketID: pending.ticket.id,
            toolName: pending.ticket.toolName,
            decision: decision
        )
        pending.receipt = receipt
        pending.mode = .interactive
        self.pendingAuthorizations[ticketID] = pending
        return receipt
    }

    func cancel(ticketID: UUID) {
        self.pendingAuthorizations.removeValue(forKey: ticketID)
    }

    func executeAuthorized(
        ticket: ToolExecutionTicket,
        receipt: ToolAuthorizationReceipt
    ) async throws -> ToolExecutionRecord {
        guard let pending = self.pendingAuthorizations[ticket.id] else {
            throw ToolHostError.invalidAuthorizationTicket
        }

        guard pending.ticket == ticket,
              let storedReceipt = pending.receipt,
              storedReceipt == receipt,
              receipt.ticketID == ticket.id,
              receipt.toolName == ticket.toolName else {
            throw ToolHostError.invalidAuthorizationReceipt
        }

        self.pendingAuthorizations.removeValue(forKey: ticket.id)

        let parameters = self.auditParameters(for: pending, receipt: receipt)
        let parametersJSON = self.serializedParameters(parameters)

        let auditEntryID = await MainActor.run {
            let params = Self.decodeParameters(from: parametersJSON)
            let entry = AuditLogger.shared.recordToolCall(
                tool: ticket.toolName,
                action: pending.action,
                category: pending.auditCategory,
                parameters: params,
                userConfirmed: pending.mode == .interactive,
                sessionID: pending.sessionID
            )
            return entry.id
        }

        do {
            let result = try await pending.tool.execute(args: ticket.args)
            let summary = result.humanSummary
            let auditResult = self.auditResultPayload(summary: summary, payload: result.auditPayload)
            let auditResultJSON = self.serializedParameters(auditResult)

            await MainActor.run {
                AuditLogger.shared.recordSuccess(
                    auditEntryID,
                    result: Self.decodeParameters(from: auditResultJSON)
                )
            }

            self.logger.info("Tool executed: \(ticket.toolName)")
            return ToolExecutionRecord(result: result, auditEntryID: auditEntryID)

        } catch {
            let errorMessage = error.localizedDescription
            let auditableFailure = error as? ToolAuditableFailure
            let failurePayload = self.auditResultPayload(
                summary: errorMessage,
                payload: auditableFailure?.auditPayload
            )
            let failurePayloadJSON = self.serializedParameters(failurePayload)

            await MainActor.run {
                AuditLogger.shared.recordFailure(
                    auditEntryID,
                    error: errorMessage,
                    result: Self.decodeParameters(from: failurePayloadJSON),
                    categoryOverride: auditableFailure?.auditCategoryOverride
                )
            }

            self.logger.error("Tool failed: \(ticket.toolName) - \(error.localizedDescription)")
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

    private func auditCategory(for toolName: String) -> AuditCategory {
        switch toolName {
        case "skills.list":
            return .skillList
        case "skills.load":
            return .skillLoad
        case "skills.read":
            return .skillRead
        case "skills.create":
            return .skillCreate
        case "skills.update":
            return .skillUpdate
        case "skills.delete":
            return .skillDelete
        case "skills.run_script":
            return .scriptExecution
        default:
            return .toolExecution
        }
    }

    private func auditParameters(
        for pending: PendingAuthorization,
        receipt: ToolAuthorizationReceipt
    ) -> [String: Any] {
        var parameters = self.jsonValueToAnyDict(pending.auditArgs)
        for (key, value) in pending.auditMetadata {
            parameters[key] = value
        }
        parameters["authorization_decision"] = receipt.decision.rawValue
        parameters["authorization_mode"] = (pending.mode ?? .interactive).rawValue
        return parameters
    }

    private func serializedParameters(_ parameters: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: parameters),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }

    private static func decodeParameters(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return decoded
    }

    private func auditResultPayload(summary: String, payload: [String: JSONValue]?) -> [String: Any] {
        var result = payload.map { self.jsonValueToAnyDict($0) } ?? [:]
        result["summary"] = summary
        return result
    }
}

// MARK: - Errors

enum ToolHostError: LocalizedError, Equatable {
    case toolNotFound(String)
    case confirmationRequired(String)
    case validationFailed(String, String)
    case invalidAuthorizationTicket
    case invalidAuthorizationReceipt
    case authorizationDenied(String)
    
    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool '\(name)' not found."
        case .confirmationRequired(let name):
            return "Tool '\(name)' requires user confirmation."
        case .validationFailed(let name, let reason):
            return "Validation failed for '\(name)': \(reason)"
        case .invalidAuthorizationTicket:
            return "The authorization ticket is no longer valid."
        case .invalidAuthorizationReceipt:
            return "The authorization receipt is invalid or has already been used."
        case .authorizationDenied(let message):
            return message
        }
    }
}
