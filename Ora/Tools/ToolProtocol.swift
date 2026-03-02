//
//  ToolProtocol.swift
//  Ora
//
//  Base protocol for all tools
//

import Foundation

/// Tool execution type
enum ToolKind: String, Sendable {
    case read    // No confirmation needed
    case mutate  // Requires confirmation
}

/// Tool loading policy for prompt injection
enum ToolLoadPolicy: Sendable, Equatable {
    case core
    case deferred
}

enum ToolAuthorizationRequirement: Sendable, Equatable {
    case none
    case userConfirmation(prompt: ToolAuthorizationPrompt)
}

enum ToolAuthorizationPresentation: Sendable, Equatable {
    case inline
    case skillDocumentPreview(content: String)
    case skillDeletion(name: String, description: String)

    var usesModalSheet: Bool {
        switch self {
        case .inline:
            return false
        case .skillDocumentPreview, .skillDeletion:
            return true
        }
    }
}

struct ToolAuthorizationPrompt: Sendable, Equatable {
    let title: String
    let summary: String
    let details: String?
    let confirmLabel: String
    let cancelLabel: String
    let trustLabel: String?
    let presentation: ToolAuthorizationPresentation

    init(
        title: String,
        summary: String,
        details: String? = nil,
        confirmLabel: String = "Confirm",
        cancelLabel: String = "Cancel",
        trustLabel: String? = nil,
        presentation: ToolAuthorizationPresentation = .inline
    ) {
        self.title = title
        self.summary = summary
        self.details = details
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.trustLabel = trustLabel
        self.presentation = presentation
    }
}

struct ToolAuthorizationPlan: Sendable {
    let requirement: ToolAuthorizationRequirement
    let auditMetadata: [String: String]
    let context: [String: JSONValue]

    init(
        requirement: ToolAuthorizationRequirement,
        auditMetadata: [String: String] = [:],
        context: [String: JSONValue] = [:]
    ) {
        self.requirement = requirement
        self.auditMetadata = auditMetadata
        self.context = context
    }
}

enum ToolAuthorizationDecision: String, Sendable {
    case approveOnce
    case approveAndTrust
    case deny
}

/// Result of tool execution
struct ToolResult: Sendable {
    let json: JSONValue
    let humanSummary: String
    let auditPayload: [String: JSONValue]?

    static func success(_ json: JSONValue, summary: String, auditPayload: [String: JSONValue]? = nil) -> ToolResult {
        ToolResult(json: json, humanSummary: summary, auditPayload: auditPayload)
    }

    static func error(_ message: String, auditPayload: [String: JSONValue]? = nil) -> ToolResult {
        ToolResult(
            json: .object(["error": .string(message)]),
            humanSummary: message,
            auditPayload: auditPayload
        )
    }
}

/// Tool definition for system prompt
struct ToolSchema: Sendable {
    let name: String
    let description: String
    let parameters: [String: ParameterSchema]
    let requiredParameters: [String]
    let requiresConfirmation: Bool
}

struct ParameterSchema: Sendable {
    let type: String  // string, number, boolean, etc.
    let description: String
    let format: String?  // date-time, email, etc.
    
    init(type: String, description: String, format: String? = nil) {
        self.type = type
        self.description = description
        self.format = format
    }
    
    var descriptionString: String {
        var desc = "\(type): \(description)"
        if let format = format {
            desc += " (\(format))"
        }
        return desc
    }
}

/// Base protocol for all tools
protocol Tool: Sendable {
    /// Unique tool name (e.g., "calendar.create_event")
    var name: String { get }
    
    /// Whether this tool mutates state
    var kind: ToolKind { get }
    
    /// Tool schema for LLM
    var schema: ToolSchema { get }

    /// Whether tool schema is included by default or discovered on demand
    var loadPolicy: ToolLoadPolicy { get }
    
    /// Validate arguments before execution
    func validate(args: [String: JSONValue]) throws

    /// Determine whether execution can proceed immediately or requires user authorization.
    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan

    /// Return a redacted or transformed argument payload for audit logging.
    func auditParameters(args: [String: JSONValue]) -> [String: JSONValue]

    /// Allow tools to persist side effects tied to an authorization decision.
    func handleAuthorizationDecision(
        args: [String: JSONValue],
        context: [String: JSONValue],
        decision: ToolAuthorizationDecision
    ) async throws
    
    /// Execute the tool
    func execute(args: [String: JSONValue]) async throws -> ToolResult
}

protocol ToolAuditableFailure: LocalizedError {
    var auditPayload: [String: JSONValue]? { get }
    var auditCategoryOverride: AuditCategory? { get }
}

extension Tool {
    /// Whether confirmation is required
    var requiresConfirmation: Bool {
        kind == .mutate
    }

    var loadPolicy: ToolLoadPolicy {
        .deferred
    }

    func authorizationPlan(args: [String: JSONValue]) async throws -> ToolAuthorizationPlan {
        if self.requiresConfirmation {
            return ToolAuthorizationPlan(
                requirement: .userConfirmation(
                    prompt: ToolAuthorizationPrompt(
                        title: "Confirm Action",
                        summary: "Allow \(self.name) to run?",
                        details: self.schema.description
                    )
                )
            )
        }

        return ToolAuthorizationPlan(requirement: .none)
    }

    func auditParameters(args: [String: JSONValue]) -> [String: JSONValue] {
        args
    }

    func handleAuthorizationDecision(
        args: [String: JSONValue],
        context: [String: JSONValue],
        decision: ToolAuthorizationDecision
    ) async throws {
        // Default tools do not persist additional authorization state.
    }
}
